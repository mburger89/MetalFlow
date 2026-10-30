import Foundation

/// Tells the user about a run that needs them, outside the window.
public protocol Notifier: Sendable {
    /// Asks the system for permission to notify; safe to call more than once.
    func requestAuthorization() async
    /// Posts (or replaces) the notification with this id.
    func post(id: String, title: String, body: String) async
    /// Removes the notification with this id.
    func remove(id: String) async
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
    public func setBadge(_ count: Int) async {}
    /// A stream that has already finished.
    public var clicks: AsyncStream<String> { AsyncStream { $0.finish() } }
}
