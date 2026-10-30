import Foundation
import Testing
@testable import MetalFlowCore

private actor Probe {
    var current = 0
    var peak = 0
    var openers: [CheckedContinuation<Void, Never>] = []
    var isOpen = false
    let entries: AsyncStream<Void>.Continuation

    init(entries: AsyncStream<Void>.Continuation) { self.entries = entries }

    func enter() async {
        current += 1
        peak = max(peak, current)
        entries.yield()
        if !isOpen { await withCheckedContinuation { openers.append($0) } }
        current -= 1
    }

    func open() {
        isOpen = true
        openers.forEach { $0.resume() }
        openers.removeAll()
    }
}

@Suite struct SessionLimiterTests {
    @Test func limiterCapsConcurrentSessions() async throws {
        let (entries, cont) = AsyncStream<Void>.makeStream()
        let probe = Probe(entries: cont)
        let limiter = SessionLimiter(max: 2)
        let tasks = (0..<5).map { _ in
            Task { try await limiter.withSlot { await probe.enter() } }
        }
        var seen = 0
        for await _ in entries {
            seen += 1
            if seen == 2 { break }
        }
        for _ in 0..<50 { await Task.yield() }
        #expect(await probe.current == 2)
        await probe.open()
        for t in tasks { try await t.value }
        #expect(await probe.peak == 2)
    }

    @Test func cancelledWaiterDoesNotRun() async throws {
        let (entries, cont) = AsyncStream<Void>.makeStream()
        let probe = Probe(entries: cont)
        let limiter = SessionLimiter(max: 1)
        let first = Task { try await limiter.withSlot { await probe.enter() } }
        for await _ in entries { break }
        let second = Task { try await limiter.withSlot { await probe.enter() } }
        for _ in 0..<50 { await Task.yield() }
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        await probe.open()
        try await first.value
        #expect(await probe.peak == 1)
    }
}
