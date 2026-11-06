import Foundation
import Testing
@testable import MetalFlowCore

/// Runs against a real Ollama; enabled only with `MF_LIVE_OLLAMA=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MF_LIVE_OLLAMA"] == "1"))
struct LocalOllamaLiveTests {
    @Test func readsAFileThroughTheLocalAgent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mf-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "MetalFlow says hi".write(to: dir.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)

        let session = LocalAgentSession(client: URLSessionChatClient(), transcripts: LocalTranscriptStore(directory: dir.appendingPathComponent("transcripts")))
        let request = AgentRequest(prompt: "Read hello.txt and tell me exactly what it says.", workingDirectory: dir,
                                   model: "qwen2.5-coder:7b", allowedTools: ["Read"], maxTurns: 6, provider: "ollama")
        var toolNames: [String] = []
        var result: AgentResult?
        for try await event in session.run(request) {
            switch event {
            case .toolUse(let name, _): toolNames.append(name)
            case .finished(let r): result = r
            default: break
            }
        }
        let final = try #require(result)
        print("live: tools=\(toolNames) turns=\(final.turns) text=\(final.text)")
        #expect(!final.isError)
        #expect(final.text.contains("MetalFlow says hi"))
        #expect(toolNames.contains { $0.lowercased() == "read" })
    }
}
