import Foundation
import Testing
import ShepitCore

@Suite struct AudioRetentionTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 24 * 60 * 60

    func recording(_ id: String, daysAgo: Double, _ status: RecordingManifest.Status) -> RecordingManifest {
        RecordingManifest(id: id, startDate: Self.now.addingTimeInterval(-daysAgo * Self.day), duration: 600,
                          app: "Zoom", status: status)
    }

    @Test func transcribedTwoDaysAgoIsKept() {
        #expect(AudioRetention.expired([recording("a", daysAgo: 2, .transcribed)], now: Self.now).isEmpty)
    }

    @Test(arguments: [3.0, 3.5, 30])
    func transcribedThreeOrMoreDaysAgoIsDeleted(daysAgo: Double) {
        let old = recording("a", daysAgo: daysAgo, .transcribed)

        #expect(AudioRetention.expired([old], now: Self.now) == [old])
    }

    @Test(arguments: [RecordingManifest.Status.failed, .stopped, .recording])
    func untranscribedOldRecordingIsNeverDeleted(status: RecordingManifest.Status) {
        #expect(AudioRetention.expired([recording("a", daysAgo: 10, status)], now: Self.now).isEmpty)
    }

    @Test func onlyExpiredOnesAreReturnedFromAMix() {
        let recordings = [
            recording("fresh", daysAgo: 1, .transcribed),
            recording("old", daysAgo: 4, .transcribed),
            recording("failed", daysAgo: 4, .failed),
        ]

        #expect(AudioRetention.expired(recordings, now: Self.now).map(\.id) == ["old"])
    }

    @Test func unfinishedMeansRecordingOrStopped() {
        #expect(recording("a", daysAgo: 0, .recording).isUnfinished)
        #expect(recording("a", daysAgo: 0, .stopped).isUnfinished)
        #expect(!recording("a", daysAgo: 0, .transcribed).isUnfinished)
        #expect(!recording("a", daysAgo: 0, .failed).isUnfinished)
    }
}
