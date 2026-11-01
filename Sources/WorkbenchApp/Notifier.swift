import Foundation
import UserNotifications

/// What is posted to the person: the project, why, and where a click goes. No sound.
struct Notice: Equatable, Sendable {
    var id: String
    var title: String
    var body: String
    var route: AttentionRoute
    /// The project it is about, so a click after another project was opened does not act on that one.
    var project: String
}

enum PostResult: Equatable, Sendable {
    case posted
    /// The system does not allow this app to notify: the count still shows and the popover says so.
    case denied
}

/// The one way a notification leaves the app, so no test posts a real one.
protocol Notifier: AnyObject, Sendable {
    func post(_ notice: Notice) async -> PostResult
}

/// Posts nothing: tests, and a launch on a fixture project (which must not ask the person for a permission).
final class NullNotifier: Notifier, @unchecked Sendable {
    func post(_ notice: Notice) async -> PostResult { .posted }
}

/// Local notifications through UserNotifications. The centre exists only in an app bundle: `swift run` has none, and asking for it
/// there ends the process, so there it posts nothing and says it was not allowed.
final class SystemNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static var hasBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Called on the main actor with where a clicked notification goes.
    @MainActor var onRoute: ((AttentionRoute, String) -> Void)?

    override init() {
        super.init()
        if Self.hasBundle { UNUserNotificationCenter.current().delegate = self }
    }

    func post(_ notice: Notice) async -> PostResult {
        guard Self.hasBundle else { return .denied }
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert])
            settings = await center.notificationSettings()
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return .denied }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.userInfo = ["route": notice.route.encoded, "project": notice.project]
        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
        do { try await center.add(request) } catch { return .denied }
        return .posted
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let text = info["route"] as? String, let route = AttentionRoute(encoded: text) else { return }
        let project = info["project"] as? String ?? ""
        await MainActor.run { onRoute?(route, project) }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner] }
}
