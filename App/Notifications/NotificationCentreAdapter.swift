import Foundation
import MemorriCore
import UserNotifications

/// Shows Memorri's notices through macOS (spec 010). Permission is asked at the first notice (or when the user switches the setting back on), never at
/// launch; nothing is shown while the Items window is in front, and a click opens the Inbox (or all items when nothing needs review).
final class NotificationCentreAdapter: NSObject, NoticeShowing, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    private let itemsAreInFront: @Sendable () async -> Bool
    private let open: @Sendable (_ inbox: Bool) -> Void

    init(itemsAreInFront: @escaping @Sendable () async -> Bool, open: @escaping @Sendable (_ inbox: Bool) -> Void) {
        self.itemsAreInFront = itemsAreInFront; self.open = open
        super.init()
        center.delegate = self
    }

    func show(_ notice: Notice) async {
        if await itemsAreInFront() { return }
        guard await authorised() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Memorri"
        content.body = notice.text
        content.userInfo = ["inbox": notice.opensInbox]
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Asks macOS when it has not been asked yet; true when notices may be shown.
    func authorised() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert])) == true
        default: return false
        }
    }

    /// For the settings row: allowed, not asked yet, or not allowed.
    func permission() async -> SyncAccess {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        open(response.notification.request.content.userInfo["inbox"] as? Bool ?? true)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner] }
}
