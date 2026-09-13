import Testing
import ShepitCore

@Suite struct MeetingSessionTests {
    static let hour: Double = 60 * 60
    static let minute: Double = 60
    static let speech: Float = -30
    static let quiet: Float = -65

    /// A session whose recording began at `time`.
    func recording(at time: Double) -> MeetingSession {
        var session = MeetingSession()
        _ = session.handle(.start, at: time)
        _ = session.handle(.started, at: time)
        return session
    }

    // MARK: Manual start and stop

    @Test func manualStartAsksToRecordAndIsRecordingOnceStarted() {
        var session = MeetingSession()

        #expect(session.handle(.start, at: 0) == [.startRecording])
        #expect(!session.isRecording)
        #expect(session.handle(.started, at: 1.5) == [])
        #expect(session.isRecording)
    }

    @Test func manualStopEndsRecording() {
        var session = recording(at: 0)

        #expect(session.handle(.stop, at: 120) == [.stopRecording])
        #expect(!session.isRecording)
    }

    @Test func failedStartReturnsToIdleSoStartWorksAgain() {
        var session = MeetingSession()

        _ = session.handle(.start, at: 0)
        #expect(session.handle(.failedToStart, at: 1) == [])
        #expect(!session.isRecording)
        #expect(session.handle(.start, at: 5) == [.startRecording])
    }

    @Test func startWhileStartingOrRecordingDoesNothing() {
        var session = MeetingSession()

        _ = session.handle(.start, at: 0)
        #expect(session.handle(.start, at: 0.5) == [])
        _ = session.handle(.started, at: 1)
        #expect(session.handle(.start, at: 10) == [])
    }

    @Test func stopWhenIdleDoesNothing() {
        var session = MeetingSession()

        #expect(session.handle(.stop, at: 0) == [])
    }

    // MARK: Long recording prompt

    @Test func asksStillRecordingAfterThreeHours() {
        var session = recording(at: 100)

        #expect(session.handle(.level(decibels: Self.speech), at: 100 + 3 * Self.hour - 2) == [])
        #expect(session.handle(.tick, at: 100 + 3 * Self.hour - 1) == [])
        #expect(session.handle(.tick, at: 100 + 3 * Self.hour) == [.askStillRecording(.longRecording)])
        #expect(session.isAskingStillRecording)
    }

    @Test func promptIsAskedOnceUntilAnswered() {
        var session = recording(at: 0)

        _ = session.handle(.tick, at: 3 * Self.hour)
        #expect(session.handle(.tick, at: 3 * Self.hour + 1) == [])
        #expect(session.handle(.tick, at: 4 * Self.hour) == [])
    }

    @Test func answeringYesKeepsRecordingAndAsksAgainThreeHoursLater() {
        var session = recording(at: 0)

        _ = session.handle(.tick, at: 3 * Self.hour)
        #expect(session.handle(.stillRecording(true), at: 3 * Self.hour + 30) == [.dismissStillRecording])
        #expect(session.isRecording)
        #expect(!session.isAskingStillRecording)
        _ = session.handle(.level(decibels: Self.speech), at: 6 * Self.hour)
        #expect(session.handle(.tick, at: 6 * Self.hour + 29) == [])
        #expect(session.handle(.tick, at: 6 * Self.hour + 30) == [.askStillRecording(.longRecording)])
    }

    @Test func answeringNoStopsRecording() {
        var session = recording(at: 0)

        _ = session.handle(.tick, at: 3 * Self.hour)
        #expect(session.handle(.stillRecording(false), at: 3 * Self.hour + 5) == [.dismissStillRecording, .stopRecording])
        #expect(!session.isRecording)
        #expect(!session.isAskingStillRecording)
    }

    @Test func manualStopDuringPromptWinsAndDismissesIt() {
        var session = recording(at: 0)

        _ = session.handle(.tick, at: 3 * Self.hour)
        #expect(session.handle(.stop, at: 3 * Self.hour + 5) == [.dismissStillRecording, .stopRecording])
        #expect(!session.isRecording)
        #expect(session.handle(.stillRecording(true), at: 3 * Self.hour + 6) == [])
        #expect(session.handle(.stillRecording(false), at: 3 * Self.hour + 7) == [])
    }

    @Test func answerWithoutPromptDoesNothing() {
        var session = recording(at: 0)

        #expect(session.handle(.stillRecording(false), at: 10) == [])
        #expect(session.isRecording)
    }

    /// Answering the silence question says nothing about whether a 3-hour recording is still wanted.
    @Test func answeringYesToSilenceKeepsThreeHourDeadline() {
        var session = recording(at: 0)

        _ = session.handle(.tick, at: 2 * Self.hour + 50 * Self.minute)
        _ = session.handle(.stillRecording(true), at: 2 * Self.hour + 51 * Self.minute)
        _ = session.handle(.level(decibels: Self.speech), at: 2 * Self.hour + 59 * Self.minute)
        #expect(session.handle(.tick, at: 3 * Self.hour) == [.askStillRecording(.longRecording)])
    }

    @Test func longRecordingPromptWinsWhenBothAreDue() {
        var session = recording(at: 0)

        #expect(session.handle(.tick, at: 3 * Self.hour) == [.askStillRecording(.longRecording)])
    }

    // MARK: Silence prompt

    @Test func asksStillRecordingAfterTenMinutesOfSilence() {
        var session = recording(at: 0)

        _ = session.handle(.level(decibels: Self.quiet), at: 5 * Self.minute)
        #expect(session.handle(.tick, at: 10 * Self.minute - 1) == [])
        #expect(session.handle(.tick, at: 10 * Self.minute) == [.askStillRecording(.silence)])
    }

    @Test func soundResetsSilenceTimer() {
        var session = recording(at: 0)

        _ = session.handle(.level(decibels: Self.speech), at: 8 * Self.minute)
        #expect(session.handle(.tick, at: 10 * Self.minute) == [])
        #expect(session.handle(.tick, at: 18 * Self.minute - 1) == [])
        #expect(session.handle(.tick, at: 18 * Self.minute) == [.askStillRecording(.silence)])
    }

    @Test func levelJustBelowThresholdCountsAsSilence() {
        var session = recording(at: 0)

        _ = session.handle(.level(decibels: MeetingSession.silenceThreshold - 0.1), at: 9 * Self.minute)
        #expect(session.handle(.tick, at: 10 * Self.minute) == [.askStillRecording(.silence)])
    }

    @Test func levelAtThresholdCountsAsSound() {
        var session = recording(at: 0)

        _ = session.handle(.level(decibels: MeetingSession.silenceThreshold), at: 9 * Self.minute)
        #expect(session.handle(.tick, at: 10 * Self.minute) == [])
    }

    @Test func answeringYesToSilenceRestartsSilenceTimer() {
        var session = recording(at: 0)

        _ = session.handle(.tick, at: 10 * Self.minute)
        _ = session.handle(.stillRecording(true), at: 12 * Self.minute)
        #expect(session.handle(.tick, at: 22 * Self.minute - 1) == [])
        #expect(session.handle(.tick, at: 22 * Self.minute) == [.askStillRecording(.silence)])
    }

    @Test func noSilencePromptBeforeRecordingStarted() {
        var session = MeetingSession()

        _ = session.handle(.start, at: 0)
        #expect(session.handle(.tick, at: 20 * Self.minute) == [])
        #expect(session.handle(.started, at: 20 * Self.minute) == [])
        #expect(session.handle(.tick, at: 21 * Self.minute) == [])
    }

    @Test func stoppedSessionCanRecordAgainWithFreshTimers() {
        var session = recording(at: 0)

        _ = session.handle(.stop, at: 9 * Self.minute)
        _ = session.handle(.start, at: 20 * Self.minute)
        _ = session.handle(.started, at: 20 * Self.minute)
        #expect(session.handle(.tick, at: 29 * Self.minute) == [])
        #expect(session.handle(.tick, at: 30 * Self.minute) == [.askStillRecording(.silence)])
    }
}
