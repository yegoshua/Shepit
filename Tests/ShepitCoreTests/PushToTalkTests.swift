import Testing
import ShepitCore

@Suite struct PushToTalkTests {
    @Test func holdingAndReleasingOptionRecordsThenFinishes() {
        var ptt = PushToTalk()

        #expect(ptt.handle(.optionDown, at: 0) == [.start])
        #expect(ptt.isRecording)
        #expect(ptt.handle(.optionUp, at: 1.5) == [.finish])
        #expect(!ptt.isRecording)
    }

    @Test func tapShorterThanMinimumIsDiscarded() {
        var ptt = PushToTalk()

        #expect(ptt.handle(.optionDown, at: 10) == [.start])
        #expect(ptt.handle(.optionUp, at: 10.2) == [.discard])
        #expect(!ptt.isRecording)
    }

    @Test func doubleTapStartsHandsFreeRecordingThatSurvivesRelease() {
        var ptt = PushToTalk()

        _ = ptt.handle(.optionDown, at: 0)
        _ = ptt.handle(.optionUp, at: 0.1)
        #expect(ptt.handle(.optionDown, at: 0.3) == [.start, .enterHandsFree])
        #expect(ptt.handle(.optionUp, at: 0.4) == [])
        #expect(ptt.isRecording)
    }

    @Test func pressInHandsFreeFinishesAndItsReleaseDoesNothing() {
        var ptt = handsFree(at: 0)

        #expect(ptt.handle(.optionDown, at: 20) == [.finish])
        #expect(!ptt.isRecording)
        #expect(ptt.handle(.optionUp, at: 20.1) == [])
        #expect(!ptt.isRecording)
    }

    @Test func secondPressAfterDoubleTapWindowIsPlainPushToTalk() {
        var ptt = PushToTalk()

        _ = ptt.handle(.optionDown, at: 0)
        _ = ptt.handle(.optionUp, at: 0.1)
        #expect(ptt.handle(.optionDown, at: 0.6) == [.start])
        #expect(ptt.handle(.optionUp, at: 2) == [.finish])
    }

    @Test func escapeCancelsPushToTalkRecording() {
        var ptt = PushToTalk()

        _ = ptt.handle(.optionDown, at: 0)
        #expect(ptt.handle(.escape, at: 1) == [.cancel])
        #expect(!ptt.isRecording)
        #expect(ptt.handle(.optionUp, at: 1.5) == [])
    }

    @Test func escapeCancelsHandsFreeRecording() {
        var ptt = handsFree(at: 0)

        #expect(ptt.handle(.escape, at: 5) == [.cancel])
        #expect(!ptt.isRecording)
    }

    @Test func escapeWhileIdleDoesNothing() {
        var ptt = PushToTalk()

        #expect(ptt.handle(.escape, at: 0) == [])
        #expect(!ptt.isRecording)
    }

    @Test func handsFreeFinishesAutomaticallyAfterFiveMinutes() {
        var ptt = handsFree(at: 0)

        #expect(ptt.handle(.tick, at: 299) == [])
        #expect(ptt.isRecording)
        #expect(ptt.handle(.tick, at: 300.3) == [.finish])
        #expect(!ptt.isRecording)
    }

    @Test func ticksWhileIdleOrHoldingDoNothing() {
        var ptt = PushToTalk()

        #expect(ptt.handle(.tick, at: 1_000) == [])
        _ = ptt.handle(.optionDown, at: 1_000)
        #expect(ptt.handle(.tick, at: 1_400) == [])
        #expect(ptt.isRecording)
    }

    @Test func pressAfterLongRecordingIsNotTreatedAsDoubleTap() {
        var ptt = PushToTalk()

        _ = ptt.handle(.optionDown, at: 0)
        _ = ptt.handle(.optionUp, at: 2)
        #expect(ptt.handle(.optionDown, at: 2.1) == [.start])
    }

    private func handsFree(at time: Double) -> PushToTalk {
        var ptt = PushToTalk()
        _ = ptt.handle(.optionDown, at: time)
        _ = ptt.handle(.optionUp, at: time + 0.1)
        _ = ptt.handle(.optionDown, at: time + 0.3)
        _ = ptt.handle(.optionUp, at: time + 0.4)
        return ptt
    }
}
