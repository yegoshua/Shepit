import Foundation

/// Reading and editing meeting files that already exist in the meetings folder,
/// including ones written or changed outside Shepit.
extension MeetingDocument {
    /// The notes prompt followed by the transcript, ready to paste into a chatbot.
    /// Notes already in the file are left out so the chatbot works from the transcript alone.
    public static func copyWithPrompt(_ markdown: String, prompt: String) -> String {
        let body = bodyLines(markdown)
        let transcript = body.firstIndex(of: transcriptHeading).map { Array(body[$0...]) } ?? body
        let text = transcript.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + text + "\n"
    }

    /// What a reader sees under the title: the file without frontmatter and title heading.
    public static func body(of markdown: String) -> String {
        var lines = bodyLines(markdown)
        if let index = titleIndex(lines, from: 0) {
            lines.remove(at: index)
            if lines.indices.contains(index), lines[index].isEmpty { lines.remove(at: index) }
        }
        return lines.joined(separator: "\n")
    }

    /// The `# ` heading that opens the body, right after the frontmatter.
    public static func title(of markdown: String) -> String? {
        let lines = bodyLines(markdown)
        return titleIndex(lines, from: 0).map { String(lines[$0].dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }

    /// Replaces the title heading, or adds one right after the frontmatter; the rest stays byte for byte.
    public static func retitled(_ markdown: String, to title: String) -> String {
        let heading = "# " + title.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        var lines = markdown.components(separatedBy: "\n")
        let start = bodyStart(lines)
        if let index = titleIndex(lines, from: start) {
            lines[index] = heading
        } else {
            lines.insert(contentsOf: [heading, ""], at: start)
        }
        return lines.joined(separator: "\n")
    }

    /// File name for a meeting the user renamed, or nil when nothing usable is left of the title.
    public static func fileName(forTitle title: String) -> String? {
        var name = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        if name.lowercased().hasSuffix(".md") { name.removeLast(3) }
        // A leading dot hides the file in Finder.
        name = String(name.drop(while: { $0 == "." || $0.isWhitespace }))
        guard name.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        // File systems allow 255 UTF-8 bytes; leave room for ".md" and a " 2" suffix.
        while name.utf8.count > maximumStemBytes { name.removeLast() }
        return name.trimmingCharacters(in: .whitespaces) + ".md"
    }

    /// `name`, or `name 2`, `name 3`… — whichever isn't taken. Compares ignoring case like the default macOS file system.
    public static func unusedFileName(_ name: String, existing: Set<String>) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var index = 2
        while taken.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            index += 1
        }
        return candidate
    }

    /// When the meeting started, from the frontmatter `date` field.
    public static func meetingDate(of markdown: String, timeZone: TimeZone = .current) -> Date? {
        guard let value = frontmatterValue("date", in: markdown) else { return nil }
        return formatter(frontmatterDatePattern, timeZone).date(from: value)
    }

    /// The value of a top-level frontmatter field, e.g. `audio`.
    public static func frontmatterValue(_ key: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: "\n")
        let prefix = key + ":"
        guard let line = lines[..<bodyStart(lines)].first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    /// Sets a frontmatter field, adding it (or the whole block) when missing; every other byte stays as it was.
    public static func settingFrontmatter(_ key: String, to value: String, in markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        let end = bodyStart(lines)
        guard end > 0 else { return (["---", "\(key): \(value)", "---"] + lines).joined(separator: "\n") }
        let prefix = key + ":"
        if let index = lines[..<end].firstIndex(where: { $0.hasPrefix(prefix) }) {
            lines[index] = "\(key): \(value)"
        } else {
            lines.insert("\(key): \(value)", at: end - 1)
        }
        return lines.joined(separator: "\n")
    }

    private static let transcriptHeading = "## Transcript"
    private static let maximumStemBytes = 240

    /// The first non-blank line from `start` when it's a `# ` heading; headings further down are sections, not the title.
    private static func titleIndex(_ lines: [String], from start: Int) -> Int? {
        guard let index = lines[start...].firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[index].hasPrefix("# ")
        else { return nil }
        return index
    }

    private static func bodyLines(_ markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: "\n")
        return Array(lines[bodyStart(lines)...])
    }

    /// Index of the first line after a leading `---` frontmatter block, or 0 without one.
    private static func bodyStart(_ lines: [String]) -> Int {
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return 0 }
        return end + 1
    }
}
