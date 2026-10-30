import Foundation
@testable import MetalFlowKit

/// A notifier that records what the model asked of it and lets a test inject clicks.
final class RecordingNotifier: Notifier, @unchecked Sendable {
    enum Event: Equatable {
        case authorize
        case post(id: String, title: String, body: String)
        case remove(id: String)
        case badge(Int)
    }

    private let lock = NSLock()
    private var _events: [Event] = []
    private var waiters: [(count: Int, resume: CheckedContinuation<Void, Never>)] = []
    let clicks: AsyncStream<String>
    private let clickContinuation: AsyncStream<String>.Continuation

    init() {
        (clicks, clickContinuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
    }

    var events: [Event] { lock.withLock { _events } }
    var posts: [Event] { events.filter { if case .post = $0 { true } else { false } } }
    var removes: [String] { events.compactMap { if case .remove(let id) = $0 { id } else { nil } } }
    var badges: [Int] { events.compactMap { if case .badge(let n) = $0 { n } else { nil } } }

    /// Injects a click on notification `id`.
    func click(_ id: String) { clickContinuation.yield(id) }

    /// Returns once at least `count` events have been recorded.
    func waitForEvents(_ count: Int) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if _events.count >= count { lock.unlock(); c.resume() } else { waiters.append((count, c)); lock.unlock() }
        }
    }

    private func record(_ event: Event) {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            _events.append(event)
            let done = waiters.filter { $0.count <= _events.count }
            waiters.removeAll { $0.count <= _events.count }
            return done.map(\.resume)
        }
        for c in ready { c.resume() }
    }

    func requestAuthorization() async { record(.authorize) }
    func post(id: String, title: String, body: String) async { record(.post(id: id, title: title, body: body)) }
    func remove(id: String) async { record(.remove(id: id)) }
    func setBadge(_ count: Int) async { record(.badge(count)) }
}
