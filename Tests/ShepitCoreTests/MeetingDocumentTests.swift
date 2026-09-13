import Foundation
import Testing
import ShepitCore

@Suite struct MeetingDocumentTests {
    static let kyiv = TimeZone(identifier: "Europe/Kyiv")!

    /// 2026-09-13 14:30:00 in Kyiv (UTC+3).
    static let startDate = Date(timeIntervalSince1970: 1_789_299_000)

    static func metadata(duration: TimeInterval = 47 * 60, app: String = "Zoom", language: String = "uk") -> MeetingMetadata {
        MeetingMetadata(startDate: startDate, duration: duration, app: app, language: language, notes: .none, audio: .kept)
    }

    @Test func rendersMicrophoneSegmentsAsTimestampedMeLines() {
        let markdown = MeetingDocument.markdown(
            me: [
                TranscriptSegment(start: 3.4, end: 6, text: " Привіт усім. "),
                TranscriptSegment(start: 75.9, end: 80, text: "Почнемо з плану."),
            ],
            metadata: Self.metadata(),
            timeZone: Self.kyiv
        )

        #expect(markdown.hasSuffix("""
        ## Transcript

        **[00:03] Me:** Привіт усім.

        **[01:15] Me:** Почнемо з плану.

        """))
    }

    @Test func startsWithFrontmatterAndTitleFollowedByTranscript() {
        let markdown = MeetingDocument.markdown(
            me: [TranscriptSegment(start: 0, end: 2, text: "Добрий день.")],
            metadata: Self.metadata(),
            timeZone: Self.kyiv
        )

        #expect(markdown == """
        ---
        date: 2026-09-13T14:30
        duration: 47m
        app: Zoom
        language: uk
        notes: none
        audio: kept
        ---
        # Meeting 13 Sep 14:30 (Zoom)

        ## Transcript

        **[00:00] Me:** Добрий день.

        """)
    }

    static let durations: [(TimeInterval, String)] = [
        (0, "0m"), (29, "0m"), (31, "1m"), (2_830, "47m"), (3_600, "1h 0m"), (5_740, "1h 36m"),
    ]

    @Test(arguments: durations)
    func durationIsRoundedToMinutes(seconds: TimeInterval, expected: String) {
        let markdown = MeetingDocument.markdown(me: [], metadata: Self.metadata(duration: seconds), timeZone: Self.kyiv)

        #expect(markdown.contains("\nduration: \(expected)\n"))
    }

    @Test func timestampsKeepCountingMinutesPastAnHour() {
        let markdown = MeetingDocument.markdown(
            me: [TranscriptSegment(start: 3_723.8, end: 3_725, text: "Наприкінці.")],
            metadata: Self.metadata(),
            timeZone: Self.kyiv
        )

        #expect(markdown.contains("**[62:03] Me:** Наприкінці."))
    }

    @Test func fileIsNamedFromDateTimeAndSource() {
        #expect(MeetingDocument.fileName(startDate: Self.startDate, app: "Zoom", timeZone: Self.kyiv)
            == "2026-09-13 14-30 Zoom.md")
    }

    @Test func fileNameReplacesCharactersFinderCannotShow() {
        #expect(MeetingDocument.fileName(startDate: Self.startDate, app: "Meet: Chrome/Arc", timeZone: Self.kyiv)
            == "2026-09-13 14-30 Meet- Chrome-Arc.md")
    }

    @Test func blankSegmentsAreLeftOut() {
        let markdown = MeetingDocument.markdown(
            me: [TranscriptSegment(start: 1, end: 2, text: "  "), TranscriptSegment(start: 5, end: 6, text: "Так.")],
            metadata: Self.metadata(),
            timeZone: Self.kyiv
        )

        #expect(markdown.hasSuffix("## Transcript\n\n**[00:05] Me:** Так.\n"))
    }

    /// Whisper fills quiet stretches with a short stock phrase spread over a whole window.
    @Test func silenceHallucinationsAreLeftOut() {
        let markdown = MeetingDocument.markdown(
            me: [
                TranscriptSegment(start: 5, end: 8, text: "Good afternoon everyone."),
                TranscriptSegment(start: 12, end: 22, text: " ."),
                TranscriptSegment(start: 22.5, end: 45, text: "Thank you."),
                TranscriptSegment(start: 50, end: 51, text: "Thank you."),
                TranscriptSegment(start: 60, end: 75, text: "So the plan for the next quarter is to ship meetings first."),
            ],
            metadata: Self.metadata(),
            timeZone: Self.kyiv
        )

        #expect(markdown.hasSuffix("""
        ## Transcript

        **[00:05] Me:** Good afternoon everyone.

        **[00:50] Me:** Thank you.

        **[01:00] Me:** So the plan for the next quarter is to ship meetings first.

        """))
    }
}
