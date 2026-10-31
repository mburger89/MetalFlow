import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct FlowModelTests {
    private func decodeNode(_ json: String) throws -> Node {
        try JSONDecoder().decode(Node.self, from: Data(json.utf8))
    }

    @Test func legacyRepoNodeDecodes() throws {
        let n = try decodeNode(#"{"id":"repo","title":"Repo","kind":{"repo":{}},"position":{"x":1,"y":2}}"#)
        #expect(n.kind == .repo(RepoConfig(mode: .thisRepo)))
    }

    @Test func legacyFlowInputDecodes() throws {
        let n = try decodeNode(#"{"id":"i","title":"Issue","kind":{"flowInput":{"_0":{"name":"issue","source":{"githubIssue":{}}}}},"position":{"x":0,"y":0}}"#)
        guard case .flowInput(let c) = n.kind else { Issue.record("not flowInput"); return }
        #expect(c.binding == .exposed(default: nil))
        #expect(n.inputs == [:])
    }

    @Test func repoConfigRoundTrips() throws {
        for mode in [RepoMode.thisRepo, .fixed(path: "/a/b"), .exposed(default: nil), .exposed(default: "/c")] {
            let node = Node(id: "r", title: "Repo", kind: .repo(RepoConfig(mode: mode)), position: Point(x: 0, y: 0),
                            inputs: ["x": .fixed("v"), "y": .exposed(default: "d")])
            let data = try JSONEncoder().encode(node)
            #expect(try JSONDecoder().decode(Node.self, from: data) == node)
        }
    }

    @Test func repoEncodesWithSynthesizedShape() throws {
        let data = try JSONEncoder().encode(NodeKind.repo(RepoConfig(mode: .thisRepo)))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        #expect(obj?["repo"]?["_0"] != nil)
        let pick = try JSONEncoder().encode(NodeKind.pick)
        #expect(String(decoding: pick, as: UTF8.self) == #"{"pick":{}}"#)
    }

    @Test func inputNamesListsPlaceholders() {
        let cfg = PromptConfig(model: "m", prompt: "{a} {b} {a}", candidates: [], allowedTools: [], maxTurns: nil)
        let judge = PromptConfig(model: "m", prompt: "{candidates} {x}", candidates: [], allowedTools: [], maxTurns: nil)
        let flow = Flow(name: "f", nodes: [
            Node(id: "p", title: "P", kind: .prompt(cfg), position: Point(x: 0, y: 0)),
            Node(id: "j", title: "J", kind: .judge(judge), position: Point(x: 0, y: 0)),
            Node(id: "s", title: "S", kind: .shell(ShellConfig(command: "echo {q}")), position: Point(x: 0, y: 0)),
            Node(id: "r", title: "R", kind: .repo(RepoConfig(mode: .thisRepo)), position: Point(x: 0, y: 0)),
        ], wires: [])
        #expect(flow.inputNames(of: "p") == ["a", "b"])
        #expect(flow.inputNames(of: "j") == ["x"])
        #expect(flow.inputNames(of: "s") == ["q"])
        #expect(flow.inputNames(of: "r") == [])
        #expect(flow.repoNodes.map(\.id) == ["r"])
    }

    @Test func builtinRepoIsExposed() {
        let repo = BuiltinFlows.fixGitHubIssue.repoNodes.first
        #expect(repo?.kind == .repo(RepoConfig(mode: .exposed(default: nil))))
    }
}
