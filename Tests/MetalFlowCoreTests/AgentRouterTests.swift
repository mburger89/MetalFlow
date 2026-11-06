import Foundation
import Testing
@testable import MetalFlowCore

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AgentRequest] = []
    var requests: [AgentRequest] { lock.withLock { items } }
    func add(_ r: AgentRequest) { lock.withLock { items.append(r) } }
}

private struct RecordingSession: AgentSession {
    let recorder = Recorder()
    func run(_ r: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        recorder.add(r)
        return AsyncThrowingStream { $0.yield(.started(sessionID: "s")); $0.finish() }
    }
}

@Suite struct AgentRouterTests {
    func request(_ model: String) -> AgentRequest {
        AgentRequest(prompt: "p", workingDirectory: URL(fileURLWithPath: "/repo"), model: model)
    }

    @Test func ollamaGoesToLocalWithoutThePrefix() async throws {
        let claude = RecordingSession(), local = RecordingSession()
        let router = AgentRouter(claude: claude, local: local)
        for try await _ in router.run(request("ollama:qwen2.5-coder:7b")) {}
        #expect(claude.recorder.requests.isEmpty)
        #expect(local.recorder.requests.map(\.model) == ["qwen2.5-coder:7b"])
        #expect(local.recorder.requests.map(\.provider) == ["ollama"])
    }

    @Test func lmstudioGoesToLocal() async throws {
        let claude = RecordingSession(), local = RecordingSession()
        let router = AgentRouter(claude: claude, local: local)
        for try await _ in router.run(request("lmstudio:llama3")) {}
        #expect(local.recorder.requests.map(\.model) == ["llama3"])
        #expect(local.recorder.requests.map(\.provider) == ["lmstudio"])
    }

    @Test func claudeNamesGoToClaudeUnchanged() async throws {
        let claude = RecordingSession(), local = RecordingSession()
        let router = AgentRouter(claude: claude, local: local)
        for try await _ in router.run(request("sonnet")) {}
        #expect(local.recorder.requests.isEmpty)
        #expect(claude.recorder.requests.map(\.model) == ["sonnet"])
        #expect(claude.recorder.requests.map(\.provider) == [nil])
    }

    @Test func splitRejectsWhatIsNotLocal() {
        #expect(AgentRouter.split(model: "ollama:") == nil)
        #expect(AgentRouter.split(model: "foo:bar") == nil)
        #expect(AgentRouter.split(model: "sonnet") == nil)
        #expect(AgentRouter.split(model: "lmstudio:y:z")?.model == "y:z")
        #expect(AgentRouter.split(model: "ollama:x")?.provider == "ollama")
    }
}
