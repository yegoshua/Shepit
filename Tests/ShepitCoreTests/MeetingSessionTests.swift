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

        #expect(session.handle(.start, at: 0) == [.startRecording(app: nil)])
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
        #expect(session.handle(.start, at: 5) == [.startRecording(app: nil)])
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

    // MARK: Call detection

    @Test func callDetectedOffersToRecordWithoutRecording() {
        var session = MeetingSession()

        #expect(session.handle(.callStarted(app: "Zoom"), at: 0) == [.offerToRecord(app: "Zoom")])
        #expect(!session.isRecording)
        #expect(session.handle(.tick, at: 60) == [])
    }

    @Test func acceptingOfferStartsRecordingForDetectedApp() {
        var session = MeetingSession()

        _ = session.handle(.callStarted(app: "Zoom"), at: 0)
        #expect(session.handle(.offerAccepted, at: 4) == [.dismissOffer, .startRecording(app: "Zoom")])
        #expect(session.handle(.started, at: 5) == [])
        #expect(session.isRecording)
    }

    @Test func dismissedOfferRecordsNothing() {
        var session = MeetingSession()

        _ = session.handle(.callStarted(app: "Zoom"), at: 0)
        #expect(session.handle(.offerDismissed, at: 3) == [.dismissOffer])
        #expect(!session.isRecording)
        #expect(session.handle(.offerAccepted, at: 4) == [])
        #expect(session.handle(.start, at: 10) == [.startRecording(app: nil)])
    }

    @Test func manualStartDuringOfferRecordsForDetectedApp() {
        var session = MeetingSession()

        _ = session.handle(.callStarted(app: "Teams"), at: 0)
        #expect(session.handle(.start, at: 2) == [.dismissOffer, .startRecording(app: "Teams")])
    }

    @Test func callEndingBeforeAnswerWithdrawsOffer() {
        var session = MeetingSession()

        _ = session.handle(.callStarted(app: "Zoom"), at: 0)
        #expect(session.handle(.callEnded(app: "Zoom"), at: 20) == [.dismissOffer])
        #expect(session.handle(.offerAccepted, at: 21) == [])
    }

    @Test func secondCallAppWhileOfferingIsIgnored() {
        var session = MeetingSession()

        _ = session.handle(.callStarted(app: "Zoom"), at: 0)
        #expect(session.handle(.callStarted(app: "Slack"), at: 1) == [])
        #expect(session.handle(.callEnded(app: "Slack"), at: 2) == [])
        #expect(session.handle(.offerAccepted, at: 3) == [.dismissOffer, .startRecording(app: "Zoom")])
    }

    @Test func detectionIsIgnoredWhileStartingOrRecording() {
        var session = MeetingSession()

        _ = session.handle(.start, at: 0)
        #expect(session.handle(.callStarted(app: "Zoom"), at: 1) == [])
        _ = session.handle(.started, at: 2)
        #expect(session.handle(.callStarted(app: "Zoom"), at: 3) == [])
    }

    @Test func manualRecordingIgnoresCallAppReleasingMic() {
        var session = recording(at: 0)

        #expect(session.handle(.callEnded(app: "Zoom"), at: 60) == [])
        #expect(session.isRecording)
    }

    /// A session recording a call that `app` was detected in.
    func recordingCall(_ app: String, at time: Double) -> MeetingSession {
        var session = MeetingSession()
        _ = session.handle(.callStarted(app: app), at: time)
        _ = session.handle(.offerAccepted, at: time)
        _ = session.handle(.started, at: time)
        return session
    }

    @Test func detectedAppReleasingMicOffersToStop() {
        var session = recordingCall("Zoom", at: 0)

        #expect(session.handle(.callEnded(app: "Slack"), at: 50) == [])
        #expect(session.handle(.callEnded(app: "Zoom"), at: 60) == [.offerToStop(app: "Zoom")])
        #expect(session.isRecording)
        #expect(session.handle(.offerAccepted, at: 65) == [.dismissOffer, .stopRecording])
        #expect(!session.isRecording)
    }

    /// The system audio permission alert can hold recording in "starting" while the call ends.
    @Test func callEndingWhileStartingOffersStopOnceStarted() {
        var session = MeetingSession()

        _ = session.handle(.callStarted(app: "Zoom"), at: 0)
        _ = session.handle(.offerAccepted, at: 1)
        #expect(session.handle(.callEnded(app: "Zoom"), at: 5) == [])
        #expect(session.handle(.started, at: 8) == [.offerToStop(app: "Zoom")])
        #expect(session.handle(.offerAccepted, at: 9) == [.dismissOffer, .stopRecording])
    }

    @Test func callResumingWhileStartingOffersNothing() {
        var session = MeetingSession()

        _ = session.handle(.callStarted(app: "Zoom"), at: 0)
        _ = session.handle(.offerAccepted, at: 1)
        _ = session.handle(.callEnded(app: "Zoom"), at: 5)
        _ = session.handle(.callStarted(app: "Zoom"), at: 6)
        #expect(session.handle(.started, at: 8) == [])
    }

    @Test func decliningStopOfferKeepsRecording() {
        var session = recordingCall("Zoom", at: 0)

        _ = session.handle(.callEnded(app: "Zoom"), at: 60)
        #expect(session.handle(.offerDismissed, at: 65) == [.dismissOffer])
        #expect(session.isRecording)
        #expect(session.handle(.offerAccepted, at: 66) == [])
    }

    @Test func detectedAppTakingMicBackWithdrawsStopOffer() {
        var session = recordingCall("Zoom", at: 0)

        _ = session.handle(.callEnded(app: "Zoom"), at: 60)
        #expect(session.handle(.callStarted(app: "Zoom"), at: 62) == [.dismissOffer])
        #expect(session.isRecording)
        #expect(session.handle(.callEnded(app: "Zoom"), at: 90) == [.offerToStop(app: "Zoom")])
    }

    @Test func manualStopDuringStopOfferDismissesIt() {
        var session = recordingCall("Zoom", at: 0)

        _ = session.handle(.callEnded(app: "Zoom"), at: 60)
        #expect(session.handle(.stop, at: 61) == [.dismissOffer, .stopRecording])
    }

    @Test func answeringNoToStillRecordingAlsoDismissesStopOffer() {
        var session = recordingCall("Zoom", at: 0)

        _ = session.handle(.callEnded(app: "Zoom"), at: 3 * Self.hour - 10)
        _ = session.handle(.tick, at: 3 * Self.hour)
        #expect(session.handle(.stillRecording(false), at: 3 * Self.hour + 1)
            == [.dismissStillRecording, .dismissOffer, .stopRecording])
    }
}
