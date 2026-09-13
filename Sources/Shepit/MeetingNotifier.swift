import AppKit
import ShepitCore
import UserNotifications

/// Posts meeting notifications; clicking "Transcript ready" opens the meeting in the Meetings window.
final class MeetingNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let fileKey = "meetingFile"

    /// Called on the main thread when the user clicks a notification about a meeting file.
    var onOpenMeeting: ((URL) -> Void)?
    /// Called on the main thread with the button chosen on "Still recording?": true keeps recording.
    var onStillRecordingAnswer: ((Bool) -> Void)?

    /// Called on the main thread with the answer to a call-detection offer: true accepts it.
    var onOfferAnswer: ((Bool) -> Void)?

    private static let stillRecordingID = "still-recording"
    /// One slot for call offers, so a stop offer replaces a stale record offer and dismissal clears either.
    private static let offerID = "call-offer"
    private static let recordOfferCategory = "recordOffer"
    private static let stopOfferCategory = "stopOffer"
    private static let acceptAction = "accept"
    private static let declineAction = "decline"
    private static let stillRecordingCategory = "stillRecording"
    private static let keepAction = "keep"
    private static let stopAction = "stop"

    /// UNUserNotificationCenter aborts outside an app bundle (e.g. `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    override init() {
        super.init()
        center?.delegate = self
        center?.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.stillRecordingCategory,
                actions: [
                    UNNotificationAction(identifier: Self.keepAction, title: "Продовжити запис"),
                    UNNotificationAction(identifier: Self.stopAction, title: "Зупинити", options: [.destructive]),
                ],
                intentIdentifiers: []
            ),
            // Closing an offer notification counts as declining it.
            UNNotificationCategory(
                identifier: Self.recordOfferCategory,
                actions: [
                    UNNotificationAction(identifier: Self.acceptAction, title: "Записати"),
                    UNNotificationAction(identifier: Self.declineAction, title: "Не треба"),
                ],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
            UNNotificationCategory(
                identifier: Self.stopOfferCategory,
                actions: [
                    UNNotificationAction(identifier: Self.acceptAction, title: "Зупинити запис", options: [.destructive]),
                    UNNotificationAction(identifier: Self.declineAction, title: "Продовжити"),
                ],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
        ])
    }

    func askStillRecording(_ reason: MeetingSession.PromptReason) {
        let body = switch reason {
        case .longRecording: "Запис зустрічі триває вже 3 години."
        case .silence: "Уже 10 хвилин нічого не чути."
        }
        post(title: "Зустріч ще записується?", body: body, userInfo: [:],
             identifier: Self.stillRecordingID, category: Self.stillRecordingCategory)
    }

    func offerToRecord(app: String) {
        post(title: "Дзвінок у \(app)", body: "Записати зустріч? Запис почнеться лише після «Записати».",
             userInfo: [:], identifier: Self.offerID, category: Self.recordOfferCategory)
    }

    func offerToStop(app: String) {
        post(title: "Дзвінок у \(app) завершився?", body: "\(app) більше не використовує мікрофон.",
             userInfo: [:], identifier: Self.offerID, category: Self.stopOfferCategory)
    }

    func dismissOffer() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.offerID])
        center?.removePendingNotificationRequests(withIdentifiers: [Self.offerID])
    }

    func dismissStillRecording() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.stillRecordingID])
        center?.removePendingNotificationRequests(withIdentifiers: [Self.stillRecordingID])
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

    private func post(title: String, body: String, userInfo: [String: String],
                      identifier: String = UUID().uuidString, category: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        center?.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error { Log.info("notification failed: \(error)") }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        switch response.actionIdentifier {
        case Self.keepAction: DispatchQueue.main.async { self.onStillRecordingAnswer?(true) }
        case Self.stopAction: DispatchQueue.main.async { self.onStillRecordingAnswer?(false) }
        case Self.acceptAction: DispatchQueue.main.async { self.onOfferAnswer?(true) }
        case Self.declineAction, UNNotificationDismissActionIdentifier:
            if response.notification.request.identifier == Self.offerID {
                DispatchQueue.main.async { self.onOfferAnswer?(false) }
            }
        default: break
        }
        if let path = response.notification.request.content.userInfo[Self.fileKey] as? String {
            DispatchQueue.main.async { self.onOpenMeeting?(URL(fileURLWithPath: path)) }
        }
        completionHandler()
    }

    /// A menu-bar app counts as frontmost often enough that banners would otherwise be hidden.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
