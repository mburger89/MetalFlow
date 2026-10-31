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

    private let legacyJSON = #"{"formatVersion":1,"flow":{"name":"x","wires":[],"nodes":[{"id":"repo","title":"Repo","kind":{"repo":{}},"position":{"x":5,"y":6}}]}}"#

    private func writeLegacy(_ json: String, dir: String?) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = dir.map { root.appendingPathComponent("repo").appendingPathComponent($0) } ?? root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("x.flow")
        try Data(json.utf8).write(to: url)
        return (root, url)
    }

    @Test func legacyFlowFileLoadsWithThisRepo() throws {
        let (root, url) = try writeLegacy(legacyJSON, dir: ".flows")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try FlowFile.load(from: url).repoNodes.map(\.kind) == [.repo(RepoConfig(mode: .thisRepo))])
    }

    @Test func legacyFlowOutsideFlowsDirLoadsExposed() throws {
        let (root, url) = try writeLegacy(legacyJSON, dir: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try FlowFile.load(from: url).repoNodes.map(\.kind) == [.repo(RepoConfig(mode: .exposed(default: nil)))])
    }

    @Test func flowWithoutRepoNodeGetsOne() throws {
        let json = #"{"formatVersion":1,"flow":{"name":"x","wires":[],"nodes":[{"id":"a","title":"A","kind":{"pick":{}},"position":{"x":300,"y":50}},{"id":"repo","title":"Mine","kind":{"pick":{}},"position":{"x":400,"y":20}}]}}"#
        let (root, url) = try writeLegacy(json, dir: ".flows")
        defer { try? FileManager.default.removeItem(at: root) }
        let flow = try FlowFile.load(from: url)
        #expect(flow.repoNodes.count == 1)
        let r = try #require(flow.repoNodes.first)
        #expect(r.id == "repo2")
        #expect(r.title == "Repo")
        #expect(r.kind == .repo(RepoConfig(mode: .thisRepo)))
        #expect(r.position == Point(x: 60, y: 20))
        #expect(flow.wires.isEmpty)
    }

    @Test func emptyFlowGetsRepoAtOrigin() throws {
        let json = #"{"formatVersion":1,"flow":{"name":"x","wires":[],"nodes":[]}}"#
        let (root, url) = try writeLegacy(json, dir: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let r = try #require(FlowFile.load(from: url).repoNodes.first)
        #expect(r.id == "repo")
        #expect(r.position == Point(x: 24, y: 24))
        #expect(r.kind == .repo(RepoConfig(mode: .exposed(default: nil))))
    }
}
