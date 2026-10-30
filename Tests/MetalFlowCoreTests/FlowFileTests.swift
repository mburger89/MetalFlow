import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct FlowFileTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("f.json")
    }

    @Test func saveThenLoadIsEqual() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FlowFile.save(BuiltinFlows.fixGitHubIssue, to: url)
        #expect(try FlowFile.load(from: url) == BuiltinFlows.fixGitHubIssue)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"formatVersion\" : 1"))
    }

    @Test func unknownFormatVersionThrows() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"formatVersion":2,"flow":{}}"#.utf8).write(to: url)
        #expect(throws: FlowFile.LoadError.unsupportedFormatVersion(2)) { try FlowFile.load(from: url) }
    }

    @Test func fixGitHubIssueValidates() throws {
        let plan = try BuiltinFlows.fixGitHubIssue.validate()
        #expect(plan.fanOut == "implement")
        #expect(plan.laneScoped == ["implement", "gate"])
    }
}
