import Foundation

/// Tells the user about a run that needs them, outside the window.
public protocol Notifier: Sendable {
    /// Asks the system for permission to notify; safe to call more than once.
    func requestAuthorization() async
    /// Posts (or replaces) the notification with this id.
    func post(id: String, title: String, body: String) async
    /// Removes the notification with this id.
    func remove(id: String) async
    /// Removes every delivered notification (stale ones from an earlier launch).
    func removeAll() async
    /// Sets the Dock badge to `count`; 0 clears it.
    func setBadge(_ count: Int) async
    /// Ids of notifications the user clicked.
    var clicks: AsyncStream<String> { get }
}

/// A notifier that does nothing: tests and headless use.
public struct NoopNotifier: Notifier {
    /// Creates a no-op notifier.
    public init() {}
    /// Does nothing.
    public func requestAuthorization() async {}
    /// Does nothing.
    public func post(id: String, title: String, body: String) async {}
    /// Does nothing.
    public func remove(id: String) async {}
    /// Does nothing.
    public func removeAll() async {}
    /// Does nothing.
    public func setBadge(_ count: Int) async {}
    /// A stream that has already finished.
    public var clicks: AsyncStream<String> { AsyncStream { $0.finish() } }
}

#if canImport(UserNotifications) && canImport(AppKit)
import AppKit
import UserNotifications

/// Posts system notifications through `UNUserNotificationCenter` and the Dock badge through `NSApp.dockTile`.
/// A process with no bundle identifier (`swift run`) cannot use the notification centre, so there it does nothing.
///
/// Notifications never activate the app: the delegate shows a banner only while the app is in the background,
/// and a click is reported through `clicks` for the model to act on.
public final class UserNotificationsNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Ids of notifications the user clicked.
    public let clicks: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let isBundled: Bool

    /// Creates a notifier. It is inert unless the process runs from an app bundle.
    public override init() {
        (clicks, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        isBundled = Bundle.main.bundleIdentifier != nil
        super.init()
        // Installed at creation, before the app finishes launching, so the click that launched the app is delivered.
        if isBundled { UNUserNotificationCenter.current().delegate = self }
    }

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    /// Asks for permission to show alerts and badges.
    public func requestAuthorization() async {
        guard isBundled else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .badge])
    }

    /// Posts (or replaces) the notification with this id.
    public func post(id: String, title: String, body: String) async {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = id
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Removes the delivered and pending notification with this id.
    public func remove(id: String) async {
        guard isBundled else { return }
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// Removes every delivered notification.
    public func removeAll() async {
        guard isBundled else { return }
        center.removeAllDeliveredNotifications()
    }

    /// Sets the Dock badge; 0 clears it.
    public func setBadge(_ count: Int) async {
        guard isBundled else { return }
        await MainActor.run { NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // In the foreground the Dashboard already shows the run: only list it, never pop a banner over the work.
        let active = await MainActor.run { NSApp?.isActive ?? false }
        return active ? [.list] : [.banner, .list]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        continuation.yield(response.notification.request.identifier)
    }
}
#endif
