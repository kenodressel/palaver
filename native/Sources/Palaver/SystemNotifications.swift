// The real UNUserNotificationCenter adapter for Notifications. Never exercised in tests (an
// unsigned build would trigger a permission prompt); tests use fakes.
import Foundation
import PalaverCore
import UserNotifications

final class SystemCenter: NSObject, NotificationCenterLike, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onClick: (([AnyHashable: Any]) -> Void)?
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func install() { center.delegate = self }

    func post(title: String, body: String, userInfo: [String: String], completion: @escaping @Sendable (Error?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = userInfo
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil), withCompletionHandler: completion)
    }

    func authorizationStatus(completion: @escaping @Sendable (NotifyPermission) -> Void) {
        center.getNotificationSettings { s in
            completion(s.authorizationStatus == .notDetermined ? .notAsked : s.authorizationStatus == .denied ? .denied : .allowed)
        }
    }

    func requestAuthorization(completion: @escaping @Sendable (Bool) -> Void) {
        center.requestAuthorization(options: [.alert]) { granted, _ in completion(granted) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        onClick?(response.notification.request.content.userInfo)
        done()
    }
}

/// osascript, as the launcher's fallback and notify.py's: title and body as script arguments.
func osascriptNotify(title: String, body: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
                   "-e", "end run", title, body]
    try? p.run()
}
