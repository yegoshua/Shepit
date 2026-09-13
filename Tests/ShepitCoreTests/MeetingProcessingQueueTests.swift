import Testing
import ShepitCore

@Suite struct MeetingProcessingQueueTests {
    typealias Queue = MeetingProcessingQueue<String>

    // MARK: One at a time

    @Test func firstMeetingRunsRightAway() {
        var queue = Queue()

        #expect(queue.handle(.enqueued("a")) == [.run("a")])
        #expect(queue.hasWork)
    }

    @Test func backToBackMeetingsRunInOrderOneAtATime() {
        var queue = Queue()

        _ = queue.handle(.enqueued("a"))
        #expect(queue.handle(.enqueued("b")) == [])
        #expect(queue.handle(.enqueued("c")) == [])
        #expect(queue.count == 3)
        #expect(queue.handle(.finished("a")) == [.run("b")])
        #expect(queue.handle(.finished("b")) == [.run("c")])
        #expect(queue.handle(.finished("c")) == [])
        #expect(!queue.hasWork)
    }

    @Test func finishingAJobThatIsNotRunningChangesNothing() {
        var queue = Queue()

        _ = queue.handle(.enqueued("a"))
        _ = queue.handle(.enqueued("b"))
        #expect(queue.handle(.finished("b")) == [])
        #expect(queue.count == 2)
    }

    // MARK: Active recording

    @Test func meetingStoppedWhileAnotherRecordsWaitsForStop() {
        var queue = Queue()

        _ = queue.handle(.recordingStarted)
        #expect(queue.handle(.enqueued("a")) == [])
        #expect(queue.isPaused)
        #expect(queue.handle(.recordingStopped) == [.run("a")])
        #expect(!queue.isPaused)
    }

    @Test func recordingStartInterruptsTheRunningJobOnce() {
        var queue = Queue()

        _ = queue.handle(.enqueued("a"))
        #expect(queue.handle(.recordingStarted) == [.interrupt("a")])
        #expect(queue.handle(.recordingStarted) == [])
    }

    @Test func interruptedJobResumesFirstAfterStop() {
        var queue = Queue()

        _ = queue.handle(.enqueued("a"))
        _ = queue.handle(.enqueued("b"))
        _ = queue.handle(.recordingStarted)
        #expect(queue.handle(.interrupted("a")) == [])
        #expect(queue.count == 2)
        #expect(queue.handle(.recordingStopped) == [.run("a")])
        #expect(queue.handle(.finished("a")) == [.run("b")])
    }

    @Test func stopBeforeTheInterruptLandsWaitsForTheJobToReport() {
        var queue = Queue()

        _ = queue.handle(.enqueued("a"))
        _ = queue.handle(.recordingStarted)
        #expect(queue.handle(.recordingStopped) == [])
        #expect(queue.handle(.interrupted("a")) == [.run("a")])
    }

    @Test func jobThatFinishesDespiteTheInterruptIsDone() {
        var queue = Queue()

        _ = queue.handle(.enqueued("a"))
        _ = queue.handle(.enqueued("b"))
        _ = queue.handle(.recordingStarted)
        #expect(queue.handle(.finished("a")) == [])
        #expect(queue.count == 1)
        #expect(queue.handle(.recordingStopped) == [.run("b")])
    }

    @Test func newRecordingAfterResumeInterruptsAgain() {
        var queue = Queue()

        _ = queue.handle(.enqueued("a"))
        _ = queue.handle(.recordingStarted)
        _ = queue.handle(.interrupted("a"))
        _ = queue.handle(.recordingStopped)
        #expect(queue.handle(.recordingStarted) == [.interrupt("a")])
    }
}
