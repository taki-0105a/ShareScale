import Foundation
import ShareScaleCore
import UserNotifications

/// 通知の口の実物（`UNUserNotificationCenter`。計画 2f-1 案 7）。許可を求めるのは `ViewerNotifications.setEnabled(true)`（利用者が設定でオンにした時）だけ。
/// バンドルの外（`swift run`）では `UNUserNotificationCenter.current()` が使えないため、`unavailable` を返して何もしない
struct SystemNotificationPoster: NotificationPosting {
    private var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func authorization() async -> NotificationAuthorization {
        guard available else { return .unavailable }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized, .provisional: return .authorized
        @unknown default: return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        guard available else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    func post(_ n: PlannedNotification) async {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        // 同じ種類の通知は同じ識別子で置き換える（通知センターに溜めない）
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: n.identifier, content: content, trigger: nil))
    }
}
