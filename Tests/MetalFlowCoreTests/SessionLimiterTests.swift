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

/// Lets a test hold and release each named holder of a slot.
private actor Gates {
    private var open: Set<String> = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var entered: [String] = []
    private let entries: AsyncStream<String>.Continuation

    init(entries: AsyncStream<String>.Continuation) { self.entries = entries }

    func hold(_ name: String) async {
        entered.append(name)
        entries.yield(name)
        if open.contains(name) { return }
        await withCheckedContinuation { waiting[name] = $0 }
    }

    func release(_ name: String) {
        open.insert(name)
        waiting.removeValue(forKey: name)?.resume()
    }
}

extension SessionLimiterTests {
    private func holder(_ name: String, _ limiter: SessionLimiter, _ gates: Gates) -> Task<Void, Error> {
        Task { try await limiter.withSlot { await gates.hold(name) } }
    }

    @Test func raisingMaxStartsWaiters() async throws {
        let (entries, cont) = AsyncStream<String>.makeStream()
        let gates = Gates(entries: cont)
        let limiter = SessionLimiter(max: 1)
        var names = entries.makeAsyncIterator()
        let first = holder("a", limiter, gates)
        #expect(await names.next() == "a")
        let second = holder("b", limiter, gates)
        for _ in 0..<50 { await Task.yield() }
        #expect(await gates.entered == ["a"])
        await limiter.setMax(2)
        #expect(await names.next() == "b")  // ran while the first still holds
        await gates.release("a")
        await gates.release("b")
        try await first.value
        try await second.value
    }

    @Test func loweringMaxStopsNoOneAndAdmitsNoOneUntilBelow() async throws {
        let (entries, cont) = AsyncStream<String>.makeStream()
        let gates = Gates(entries: cont)
        let limiter = SessionLimiter(max: 2)
        var names = entries.makeAsyncIterator()
        let a = holder("a", limiter, gates)
        let b = holder("b", limiter, gates)
        _ = await names.next()
        _ = await names.next()
        let c = holder("c", limiter, gates)
        await limiter.setMax(1)
        for _ in 0..<50 { await Task.yield() }
        #expect(await gates.entered.count == 2, "lowering stops no one")
        await gates.release("a")
        try await a.value
        for _ in 0..<50 { await Task.yield() }
        #expect(await gates.entered.count == 2, "one holder is still at the new limit")
        await gates.release("b")
        #expect(await names.next() == "c")
        await gates.release("c")
        try await b.value
        try await c.value
    }

    @Test func raisingMaxSkipsACancelledWaiter() async throws {
        let (entries, cont) = AsyncStream<String>.makeStream()
        let gates = Gates(entries: cont)
        let limiter = SessionLimiter(max: 1)
        var names = entries.makeAsyncIterator()
        let a = holder("a", limiter, gates)
        #expect(await names.next() == "a")
        let b = holder("b", limiter, gates)
        for _ in 0..<50 { await Task.yield() }
        let c = holder("c", limiter, gates)
        for _ in 0..<50 { await Task.yield() }
        b.cancel()
        await #expect(throws: CancellationError.self) { try await b.value }
        await limiter.setMax(2)
        #expect(await names.next() == "c")
        #expect(await gates.entered == ["a", "c"])
        await gates.release("a")
        await gates.release("c")
        try await a.value
        try await c.value
    }

    @Test func maxNeverDropsBelowOne() async {
        let limiter = SessionLimiter(max: 3)
        await limiter.setMax(0)
        #expect(await limiter.max == 1)
    }
}
