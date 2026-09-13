import Foundation
import Testing
import ShepitCore

@Suite struct MeetingFileTests {
    static let kyiv = TimeZone(identifier: "Europe/Kyiv")!

    static let document = """
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

    **[00:02] Me:** Привіт, чути мене?

    **[00:06] Others:** Так, чудово чути.

    """

    // MARK: Copy with prompt

    @Test func copyWithPromptPutsPromptBeforeTranscript() {
        let text = MeetingDocument.copyWithPrompt(Self.document, prompt: "Зроби нотатки зустрічі.\n")

        #expect(text == """
        Зроби нотатки зустрічі.

        ## Transcript

        **[00:02] Me:** Привіт, чути мене?

        **[00:06] Others:** Так, чудово чути.

        """)
    }

    @Test func copyWithPromptLeavesOutNotesAboveTheTranscript() {
        let withNotes = Self.document.replacingOccurrences(
            of: "## Transcript", with: "## Summary\n\nСтарі нотатки.\n\n## Transcript"
        )

        let text = MeetingDocument.copyWithPrompt(withNotes, prompt: "Prompt")

        #expect(!text.contains("Старі нотатки."))
        #expect(text.contains("**[00:06] Others:** Так, чудово чути."))
    }

    /// Files added by hand may have no frontmatter or Transcript heading at all.
    @Test func copyWithPromptUsesWholeBodyWithoutTranscriptHeading() {
        let text = MeetingDocument.copyWithPrompt("---\napp: Zoom\n---\n# Планування\n\nМи домовились.\n", prompt: "Prompt")

        #expect(text == "Prompt\n\n# Планування\n\nМи домовились.\n")
    }

    // MARK: Preview

    @Test func bodyLeavesOutFrontmatterAndTitle() {
        #expect(MeetingDocument.body(of: Self.document) == """
        ## Transcript

        **[00:02] Me:** Привіт, чути мене?

        **[00:06] Others:** Так, чудово чути.

        """)
    }

    @Test func bodyOfPlainTextIsTheWholeText() {
        #expect(MeetingDocument.body(of: "Ми домовились.\n") == "Ми домовились.\n")
    }

    // MARK: Title

    @Test func titleIsTheFirstHeadingAfterFrontmatter() {
        #expect(MeetingDocument.title(of: Self.document) == "Meeting 13 Sep 14:30 (Zoom)")
    }

    @Test func titleIsNilWithoutHeading() {
        #expect(MeetingDocument.title(of: "Просто текст.\n## Transcript\n") == nil)
    }

    @Test func retitlingReplacesOnlyTheTitleLine() {
        let renamed = MeetingDocument.retitled(Self.document, to: "  Бюджет на Q4 ")

        #expect(renamed == Self.document.replacingOccurrences(
            of: "# Meeting 13 Sep 14:30 (Zoom)", with: "# Бюджет на Q4"
        ))
    }

    @Test func retitlingAddsTitleAfterFrontmatterWhenMissing() {
        let renamed = MeetingDocument.retitled("---\napp: Zoom\n---\nМи домовились.\n", to: "Планування")

        #expect(renamed == "---\napp: Zoom\n---\n# Планування\n\nМи домовились.\n")
    }

    /// A hand-written file's section heading further down isn't its title.
    @Test func retitlingKeepsHeadingsFurtherDownTheBody() {
        let renamed = MeetingDocument.retitled("Вступ.\n\n# Розділ\n", to: "Нова")

        #expect(renamed == "# Нова\n\nВступ.\n\n# Розділ\n")
    }

    @Test func titleMayFollowBlankLinesAfterFrontmatter() {
        #expect(MeetingDocument.title(of: "---\napp: Zoom\n---\n\n# Планування\n") == "Планування")
    }

    @Test func headingBelowOtherTextIsNotTheTitle() {
        #expect(MeetingDocument.title(of: "Вступ.\n\n# Розділ\n") == nil)
    }

    // MARK: Rename-safe file names

    @Test func fileNameForTitleAddsMarkdownExtension() {
        #expect(MeetingDocument.fileName(forTitle: "Бюджет на Q4") == "Бюджет на Q4.md")
    }

    @Test func fileNameForTitleReplacesSeparatorsAndCollapsesWhitespace() {
        #expect(MeetingDocument.fileName(forTitle: "  1:1 з Олею /\n план  ") == "1-1 з Олею - план.md")
    }

    @Test func fileNameForTitleDropsLeadingDotsSoFileStaysVisible() {
        #expect(MeetingDocument.fileName(forTitle: "..hidden") == "hidden.md")
    }

    @Test func fileNameForTitleDoesNotDoubleExtension() {
        #expect(MeetingDocument.fileName(forTitle: "Нотатки.md") == "Нотатки.md")
    }

    @Test(arguments: ["", "   ", "\n", "..", "/"])
    func fileNameForBlankTitleIsNil(title: String) {
        #expect(MeetingDocument.fileName(forTitle: title) == nil)
    }

    @Test func fileNameForTitleStaysWithinFileSystemLimit() {
        let name = MeetingDocument.fileName(forTitle: String(repeating: "Зустріч ", count: 60))

        #expect(name.map { $0.utf8.count <= 255 } == true)
        #expect(name?.hasSuffix(".md") == true)
    }

    @Test func unusedFileNameKeepsFreeName() {
        #expect(MeetingDocument.unusedFileName("Бюджет.md", existing: ["Інше.md"]) == "Бюджет.md")
    }

    @Test func unusedFileNameAppendsNextFreeNumber() {
        let existing: Set = ["Бюджет.md", "Бюджет 2.md"]

        #expect(MeetingDocument.unusedFileName("Бюджет.md", existing: existing) == "Бюджет 3.md")
    }

    /// The default macOS file system ignores case, so "budget.md" would overwrite "Budget.md".
    @Test func unusedFileNameComparesIgnoringCase() {
        #expect(MeetingDocument.unusedFileName("budget.md", existing: ["Budget.md"]) == "budget 2.md")
    }

    // MARK: Date

    @Test func meetingDateComesFromFrontmatter() {
        #expect(MeetingDocument.meetingDate(of: Self.document, timeZone: Self.kyiv)
            == Date(timeIntervalSince1970: 1_789_299_000))
    }

    @Test(arguments: ["# Без frontmatter\n", "---\ndate: вчора\n---\n", "---\napp: Zoom\n---\n"])
    func meetingDateIsNilWhenMissingOrMalformed(markdown: String) {
        #expect(MeetingDocument.meetingDate(of: markdown, timeZone: Self.kyiv) == nil)
    }
}
