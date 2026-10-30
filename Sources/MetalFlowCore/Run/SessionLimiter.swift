import Foundation

/// Caps how many agent sessions run at once; extra callers wait in FIFO order.
public actor SessionLimiter {
    private let max: Int
    private var active = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    /// Creates a limiter allowing `max` concurrent bodies (at least one).
    public init(max: Int) { self.max = Swift.max(1, max) }

    /// Waits for a free slot, runs `body` while holding it, then releases the slot.
    /// Cancellation while waiting throws `CancellationError` without running `body`.
    public func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        if active < max { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    c.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, c))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().continuation.resume()  // the slot passes straight to the next waiter
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
