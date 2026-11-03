import Foundation
import os
@testable import MetalFlowCore

/// Scriptable `AgentSession` for tests. The latest matching script wins; unmatched requests throw.
final class FakeAgent: AgentSession {
    struct Unscripted: Error { var request: AgentRequest }

    private struct Script {
        var match: @Sendable (AgentRequest) -> Bool
        var effect: (@Sendable (AgentRequest) throws -> Void)?
        var events: [AgentEvent]
        var hold: AsyncStream<Void>?
        var thenThrow: (any Error)?
    }

    private struct State {
        var scripts: [Script] = []
        var requests: [AgentRequest] = []
        var cancelledCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// How many sessions were cut short by cancellation.
    var cancelledCount: Int { state.withLock { $0.cancelledCount } }

    /// Every request passed to `run`, in order.
    var requests: [AgentRequest] { state.withLock { $0.requests } }

    /// Registers a script. `effect` runs before events are yielded; when `hold` is set, the fake awaits its
    /// first element (or its end) before yielding `.finished`.
    func script(
        _ match: @escaping @Sendable (AgentRequest) -> Bool,
        effect: (@Sendable (AgentRequest) throws -> Void)? = nil,
        hold: AsyncStream<Void>? = nil,
        events: [AgentEvent]
    ) {
        state.withLock { $0.scripts.append(Script(match: match, effect: effect, events: events, hold: hold)) }
    }

    /// Registers a script that yields `events` and then fails its stream with `error`.
    func script(_ match: @escaping @Sendable (AgentRequest) -> Bool, events: [AgentEvent], thenThrowing error: any Error) {
        state.withLock { $0.scripts.append(Script(match: match, effect: nil, events: events, hold: nil, thenThrow: error)) }
    }

    /// Registers a script whose stream fails with `error` as soon as it starts.
    func script(_ match: @escaping @Sendable (AgentRequest) -> Bool, throwing error: any Error) {
        script(match, effect: { _ in throw error }, events: [])
    }

    func run(_ r: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        let script: Script? = state.withLock { s in
            s.requests.append(r)
            return s.scripts.last { $0.match(r) }
        }
        return AsyncThrowingStream { continuation in
            guard let script else {
                continuation.finish(throwing: Unscripted(request: r))
                return
            }
            let task = Task {
                do {
                    try script.effect?(r)
                    for event in script.events {
                        if case .finished = event, let hold = script.hold {
                            var it = hold.makeAsyncIterator()
                            _ = await it.next()
                            try Task.checkCancellation()
                        }
                        continuation.yield(event)
                    }
                    if let failure = script.thenThrow { throw failure }
                    continuation.finish()
                } catch {
                    if error is CancellationError { state.withLock { $0.cancelledCount += 1 } }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
