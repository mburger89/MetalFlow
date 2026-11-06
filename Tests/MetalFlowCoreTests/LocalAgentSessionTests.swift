import Foundation
import Testing
@testable import MetalFlowCore

private final class ScriptedClient: LocalChatClient, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [ChatReply]
    private let repeating: ChatReply?
    private let delay: Duration?
    private var sent: [[ChatMessage]] = []
    private var specNames: [[String]] = []

    init(_ replies: [ChatReply], repeating: ChatReply? = nil, delay: Duration? = nil) {
        self.replies = replies
        self.repeating = repeating
        self.delay = delay
    }

    var calls: [[ChatMessage]] { lock.withLock { sent } }
    var tools: [[String]] { lock.withLock { specNames } }

    func complete(provider: LocalProvider, model: String, messages: [ChatMessage], tools: [ToolSpec]) async throws -> ChatReply {
        if let delay { try await Task.sleep(for: delay) }
        return lock.withLock {
            sent.append(messages)
            specNames.append(tools.map(\.name))
            if !replies.isEmpty { return replies.removeFirst() }
            return repeating ?? ChatReply(content: "done")
        }
    }
}

@Suite struct LocalAgentSessionTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mf-local-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func request(_ dir: URL, allowed: [String] = [], maxTurns: Int? = nil, resume: String? = nil, provider: String? = "ollama") -> AgentRequest {
        AgentRequest(prompt: "go", workingDirectory: dir, model: "m", allowedTools: allowed, maxTurns: maxTurns, resumeSessionID: resume, provider: provider)
    }

    func collect(_ s: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
        var out: [AgentEvent] = []
        for try await e in s { out.append(e) }
        return out
    }

    func result(_ events: [AgentEvent]) -> AgentResult? {
        for e in events { if case .finished(let r) = e { return r } }
        return nil
    }

    func call(_ id: String, _ name: String, _ args: String) -> ToolCall { ToolCall(id: id, name: name, arguments: args) }

    @Test func plainAnswer() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = ScriptedClient([ChatReply(content: "hello")])
        let session = LocalAgentSession(client: client, transcripts: LocalTranscriptStore(directory: dir.appendingPathComponent("t")))
        let events = try await collect(session.run(request(dir)))
        guard case .started(let id) = events.first else { Issue.record("no start"); return }
        #expect(id.hasPrefix("local-"))
        #expect(events[1] == .text("hello"))
        let r = try #require(result(events))
        #expect(r.text == "hello" && !r.isError && r.costUSD == 0 && r.turns == 1 && r.sessionID == id)
        let sent = client.calls[0]
        #expect(sent[0].role == .system && sent[0].content == LocalAgentSession.systemPrompt)
        #expect(sent.last == ChatMessage(role: .user, content: "go"))
        #expect(client.tools[0] == ["read", "grep", "glob", "edit", "write", "bash"])
    }

    @Test func toolCallThenAnswer() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "contents".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let client = ScriptedClient([
            ChatReply(toolCalls: [call("c1", "read", #"{"path":"a.txt"}"#)]),
            ChatReply(content: "it says contents"),
        ])
        let session = LocalAgentSession(client: client, transcripts: LocalTranscriptStore(directory: dir.appendingPathComponent("t")))
        let events = try await collect(session.run(request(dir, allowed: ["Read"])))
        #expect(events.contains(.toolUse(name: "read", summary: #"{"path":"a.txt"}"#)))
        let r = try #require(result(events))
        #expect(r.text == "it says contents" && r.turns == 2 && r.deniedTools.isEmpty)
        let tool = try #require(client.calls[1].last)
        #expect(tool.role == .tool && tool.toolCallID == "c1" && tool.content?.contains("contents") == true)
    }

    @Test func deniedToolIsRecordedAndReported() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = ScriptedClient([
            ChatReply(toolCalls: [call("c1", "write", #"{"path":"x.txt","content":"hi"}"#), call("c2", "write", #"{"path":"y.txt","content":"hi"}"#)]),
            ChatReply(content: "ok"),
        ])
        let session = LocalAgentSession(client: client, transcripts: LocalTranscriptStore(directory: dir.appendingPathComponent("t")))
        let r = try #require(result(try await collect(session.run(request(dir, allowed: ["Read"])))))
        #expect(r.deniedTools == ["Write"])
        let second = client.calls[1]
        #expect(second.suffix(2).allSatisfy { $0.content == "Denied: Write is not allowed for this node." })
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.txt").path))
    }

    @Test func resumeSendsEarlierMessagesFirst() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalTranscriptStore(directory: dir.appendingPathComponent("t"))
        let earlier = [
            ChatMessage(role: .system, content: "old system"),
            ChatMessage(role: .user, content: "first"),
            ChatMessage(role: .assistant, content: "answer"),
        ]
        try store.save(sessionID: "local-old", messages: earlier)
        let client = ScriptedClient([ChatReply(content: "again")])
        let events = try await collect(LocalAgentSession(client: client, transcripts: store).run(request(dir, resume: "local-old")))
        #expect(events.first == .started(sessionID: "local-old"))
        #expect(Array(client.calls[0].prefix(3)) == earlier)
        #expect(client.calls[0].last == ChatMessage(role: .user, content: "go"))
        let saved = try store.load(sessionID: "local-old")
        #expect(saved.count == 5 && saved.last?.content == "again")
    }

    @Test func turnLimitIsAnError() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = ScriptedClient([], repeating: ChatReply(toolCalls: [call("c", "glob", #"{"pattern":"*"}"#)]))
        let session = LocalAgentSession(client: client, transcripts: LocalTranscriptStore(directory: dir.appendingPathComponent("t")))
        let r = try #require(result(try await collect(session.run(request(dir, allowed: ["Glob"], maxTurns: 2)))))
        #expect(r.isError && r.turns == 2 && r.text.contains("turn limit"))
        #expect(client.calls.count == 2)
    }

    @Test func questionLineIsExposed() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = ScriptedClient([ChatReply(content: "stuck\nQUESTION: which branch?")])
        let session = LocalAgentSession(client: client, transcripts: LocalTranscriptStore(directory: dir.appendingPathComponent("t")))
        let r = try #require(result(try await collect(session.run(request(dir)))))
        #expect(r.question == "which branch?")
    }

    @Test func cancellationStopsTheLoop() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = ScriptedClient([], repeating: ChatReply(toolCalls: [call("c", "glob", #"{"pattern":"*"}"#)]), delay: .milliseconds(40))
        let session = LocalAgentSession(client: client, transcripts: LocalTranscriptStore(directory: dir.appendingPathComponent("t")))
        for try await event in session.run(request(dir, allowed: ["Glob"], maxTurns: 1000)) {
            if case .toolUse = event { break }
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(client.calls.count < 5)
    }

    @Test func badProviderThrows() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = LocalAgentSession(client: ScriptedClient([]), transcripts: LocalTranscriptStore(directory: dir.appendingPathComponent("t")))
        for provider in [nil, "openai"] {
            await #expect(throws: LocalAgentError.self) { _ = try await collect(session.run(request(dir, provider: provider))) }
        }
    }
}
