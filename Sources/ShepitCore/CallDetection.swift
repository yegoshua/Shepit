import Foundation

/// An app whose microphone use suggests a call worth recording.
public struct CallApp: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var bundleID: String

    public var id: String { bundleID }

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }

    /// Also matches helper processes such as `com.google.Chrome.helper`, where browsers capture audio.
    public func matches(bundleID other: String) -> Bool {
        let own = bundleID.lowercased()
        let other = other.lowercased()
        return other == own || other.hasPrefix(own + ".")
    }

    public static let defaults: [CallApp] = [
        CallApp(name: "Zoom", bundleID: "us.zoom.xos"),
        CallApp(name: "Microsoft Teams", bundleID: "com.microsoft.teams2"),
        CallApp(name: "Microsoft Teams (classic)", bundleID: "com.microsoft.teams"),
        CallApp(name: "Slack", bundleID: "com.tinyspeck.slackmacgap"),
        CallApp(name: "FaceTime", bundleID: "com.apple.FaceTime"),
        CallApp(name: "Telegram", bundleID: "ru.keepcoder.Telegram"),
        CallApp(name: "Telegram Desktop", bundleID: "com.tdesktop.Telegram"),
        CallApp(name: "Google Chrome", bundleID: "com.google.Chrome"),
        CallApp(name: "Arc", bundleID: "company.thebrowser.Browser"),
        CallApp(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        CallApp(name: "Brave", bundleID: "com.brave.Browser"),
        CallApp(name: "Firefox", bundleID: "org.mozilla.firefox"),
        // Safari captures audio in the shared WebKit GPU process, so this also covers other WebKit apps.
        CallApp(name: "Safari", bundleID: "com.apple.WebKit.GPU"),
    ]
}

/// One Core Audio client process as seen at a moment in time.
public struct AudioInputProcess: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    public var isRunningInput: Bool

    public init(pid: Int32, bundleID: String?, isRunningInput: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningInput = isRunningInput
    }
}

public enum CallDetection {
    /// Names of watched apps currently taking microphone input. Shepit's own process never counts,
    /// so dictation can't trigger an offer.
    public static func activeApps(in processes: [AudioInputProcess], watching apps: [CallApp], ownPID: Int32) -> Set<String> {
        var active = Set<String>()
        for process in processes where process.isRunningInput && process.pid != ownPID {
            guard let bundleID = process.bundleID, let app = apps.first(where: { $0.matches(bundleID: bundleID) }) else { continue }
            active.insert(app.name)
        }
        return active
    }

    /// Session events between two snapshots of active apps: endings first, each group in name order.
    public static func changes(from previous: Set<String>, to current: Set<String>) -> [MeetingSession.Event] {
        previous.subtracting(current).sorted().map { .callEnded(app: $0) }
            + current.subtracting(previous).sorted().map { .callStarted(app: $0) }
    }
}
