import Foundation
import MetalFlowCore

/// Tells the user about a run that needs them, outside the window. Task 7 adds the real implementation.
@MainActor
public protocol Notifier: AnyObject {
    /// Posts a notification for a run that needs the user.
    func notifyNeedsYou(runID: RunID, title: String, body: String)
    /// Sets the Dock badge to `count`; 0 clears it.
    func setBadge(_ count: Int)
}

/// A notifier that does nothing: tests and headless use.
@MainActor
public final class NoopNotifier: Notifier {
    /// Creates a no-op notifier.
    public init() {}
    /// Does nothing.
    public func notifyNeedsYou(runID: RunID, title: String, body: String) {}
    /// Does nothing.
    public func setBadge(_ count: Int) {}
}
