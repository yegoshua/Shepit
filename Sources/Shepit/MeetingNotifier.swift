import AppKit
import UserNotifications

/// Posts meeting notifications; clicking "Transcript ready" opens the meeting file.
final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let fileKey = "meetingFile"

    /// UNUserNotificationCenter aborts outside an app bundle (e.g. `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    override init() {
        super.init()
        center?.delegate = self
    }

    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.info("notifications granted=\(granted) \(error.map { "\($0)" } ?? "")")
        }
    }

    func transcriptReady(_ file: URL) {
        post(title: "Транскрипт готовий", body: file.deletingPathExtension().lastPathComponent,
             userInfo: [Self.fileKey: file.path])
    }

    func othersUnavailable(_ message: String) {
        post(title: "Записую лише мікрофон", body: message, userInfo: [:])
    }

    func failed(_ message: String) {
        post(title: "Зустріч не розшифровано", body: message, userInfo: [:])
    }

    private func post(title: String, body: String, userInfo: [String: String]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        content.sound = .default
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { Log.info("notification failed: \(error)") }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo[Self.fileKey] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        completionHandler()
    }

    /// A menu-bar app counts as frontmost often enough that banners would otherwise be hidden.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
