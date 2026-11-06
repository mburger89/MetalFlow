import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct LocalTranscriptStoreTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mf-transcripts-" + UUID().uuidString)
    }

    @Test func roundTrips() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalTranscriptStore(directory: dir)
        let messages = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .assistant, content: nil, toolCalls: [ToolCall(id: "1", name: "read", arguments: "{}")]),
            ChatMessage(role: .tool, content: "out", toolCallID: "1"),
        ]
        try store.save(sessionID: "local-abc", messages: messages)
        #expect(try store.load(sessionID: "local-abc") == messages)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("local-abc.json").path))
    }

    @Test func missingSessionIsEmpty() throws {
        let store = LocalTranscriptStore(directory: tempDir())
        #expect(try store.load(sessionID: "nope").isEmpty)
    }

    @Test func pathLikeIDsAreRefused() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalTranscriptStore(directory: dir)
        for id in ["../x", "a/b", "..", "a..b", ""] {
            #expect(throws: InvalidLocalSessionID.self) { try store.load(sessionID: id) }
            #expect(throws: InvalidLocalSessionID.self) { try store.save(sessionID: id, messages: []) }
        }
    }
}
