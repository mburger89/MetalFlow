import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct ClaudeCLITests {
    let dir = URL(fileURLWithPath: "/tmp/work")

    func request(maxTurns: Int? = nil, resume: String? = nil) -> AgentRequest {
        AgentRequest(prompt: "do it", workingDirectory: dir, model: "haiku", allowedTools: ["Read", "Edit"], maxTurns: maxTurns, resumeSessionID: resume)
    }

    func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
        var events: [AgentEvent] = []
        for try await e in stream { events.append(e) }
        return events
    }

    @Test func cliBuildsArguments() async throws {
        let runner = FakeCommandRunner()
        runner.stubLines("claude", [], lines: try fixtureLines("success"))
        _ = try await collect(ClaudeCLI(runner: runner).run(request(maxTurns: 5, resume: "s1")))
        let call = try #require(runner.calls.first)
        let a = call.arguments
        #expect(a.starts(with: ["-p", "do it", "--output-format", "stream-json", "--verbose", "--permission-mode", "default", "--model", "haiku", "--allowedTools", "Read,Edit"]))
        #expect(a.joined(separator: " ").contains("--max-turns 5 --resume s1 --append-system-prompt " + ClaudeCLI.questionConvention))
        #expect(call.workingDirectory == dir)
        #expect(call.executable == "claude")
    }

    @Test func omitsOptionalFlags() async throws {
        let runner = FakeCommandRunner()
        runner.stubLines("claude", [], lines: try fixtureLines("success"))
        _ = try await collect(ClaudeCLI(runner: runner).run(request()))
        let a = try #require(runner.calls.first).arguments
        #expect(!a.contains("--max-turns") && !a.contains("--resume"))
    }

    @Test func nonZeroExitAfterResultStillFinishes() async throws {
        let runner = FakeCommandRunner()
        runner.stubLines("claude", [], lines: try fixtureLines("success"), exitCode: 1)
        let events = try await collect(ClaudeCLI(runner: runner).run(request()))
        guard case .finished? = events.last else { Issue.record("no finished"); return }
    }

    @Test func nonZeroExitWithoutResultThrows() async throws {
        let runner = FakeCommandRunner()
        runner.stubLines("claude", [], lines: [#"{"type":"system","subtype":"init","session_id":"x"}"#], exitCode: 1)
        await #expect(throws: CommandError.self) { try await collect(ClaudeCLI(runner: runner).run(request())) }
    }

    @Test func malformedLineThrows() async throws {
        let runner = FakeCommandRunner()
        runner.stubLines("claude", [], lines: ["garbage"])
        await #expect(throws: ClaudeStreamError.self) { try await collect(ClaudeCLI(runner: runner).run(request())) }
    }

    @Test func cancellingConsumerCancelsUnderlyingStream() async throws {
        let (flag, flagCont) = AsyncStream<Void>.makeStream()
        let runner = HangingRunner(onTerminate: { flagCont.yield() })
        let task = Task {
            for try await _ in ClaudeCLI(runner: runner).run(request()) {}
        }
        for await _ in runner.started { break }
        task.cancel()
        for await _ in flag { break }
        _ = try? await task.value
    }

    @Test func fakeAgentScriptsEffectsAndRecords() async throws {
        let agent = FakeAgent()
        let result = AgentResult(sessionID: "s", text: "ok", isError: false, deniedTools: [], costUSD: 0, turns: 1)
        agent.script({ $0.prompt == "do it" }, effect: { _ in }, events: [.started(sessionID: "s"), .finished(result)])
        let events = try await collect(agent.run(request()))
        #expect(events == [.started(sessionID: "s"), .finished(result)])
        #expect(agent.requests.count == 1)
        await #expect(throws: FakeAgent.Unscripted.self) {
            try await collect(agent.run(AgentRequest(prompt: "other", workingDirectory: dir, model: "m")))
        }
    }

    @Test func fakeAgentHoldKeepsSessionRunning() async throws {
        let agent = FakeAgent()
        let (hold, holdCont) = AsyncStream<Void>.makeStream()
        let result = AgentResult(sessionID: "s", text: "ok", isError: false, deniedTools: [], costUSD: 0, turns: 1)
        agent.script({ _ in true }, hold: hold, events: [.started(sessionID: "s"), .finished(result)])
        var it = agent.run(request()).makeAsyncIterator()
        #expect(try await it.next() == .started(sessionID: "s"))
        holdCont.yield()
        #expect(try await it.next() == .finished(result))
        #expect(try await it.next() == nil)
    }
}

/// A runner whose `lines` stream never produces output and reports when it is terminated.
private final class HangingRunner: CommandRunner {
    let started: AsyncStream<Void>
    private let startedCont: AsyncStream<Void>.Continuation
    private let onTerminate: @Sendable () -> Void

    init(onTerminate: @escaping @Sendable () -> Void) {
        (started, startedCont) = AsyncStream<Void>.makeStream()
        self.onTerminate = onTerminate
    }

    func run(_ c: Command) async throws -> CommandResult { CommandResult(exitCode: 0, stdout: "", stderr: "") }

    func lines(_ c: Command) -> AsyncThrowingStream<String, Error> {
        let started = startedCont, onTerminate = onTerminate
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in onTerminate() }
            started.yield()
        }
    }
}
