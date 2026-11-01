import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct LaunchArgumentsTests {
    private func entry(_ name: String, _ path: String?) -> FlowEntry {
        let file = path.map { URL(fileURLWithPath: $0) }
        return FlowEntry(id: path ?? "builtin:\(name)", name: name, location: file.map { .library(file: $0) } ?? .builtin, file: file)
    }

    @Test func parsesRepeatedSet() throws {
        let a = try LaunchArguments.parseSet("issue=7")
        let b = try LaunchArguments.parseSet("env=a=b")
        let c = try LaunchArguments.parseSet("note=")
        #expect(a == ("issue", "7"))
        #expect(b == ("env", "a=b"))
        #expect(c == ("note", ""))
        let fields = [LaunchField(name: "issue", kind: .githubIssue), LaunchField(name: "env", kind: .text),
                      LaunchField(name: "repo", kind: .repo)]
        let v = try LaunchArguments.values(fields: fields, positional: nil, sets: [a, b])
        #expect(v == ["issue": "7", "env": "a=b"])
    }

    @Test func badSetFails() {
        for bad in ["noequals", "=value", ""] {
            #expect(throws: LaunchArgumentError.badSet(bad)) { _ = try LaunchArguments.parseSet(bad) }
        }
        #expect(LaunchArgumentError.badSet("x").localizedDescription.contains("expected --set name=value"))
        #expect(throws: LaunchArgumentError.unknownInput("nope")) {
            _ = try LaunchArguments.values(fields: [], positional: nil, sets: [("nope", "1")])
        }
    }

    @Test func flowByName() throws {
        let entries = [entry("Fix GitHub issue", nil), entry("Deploy", "/lib/deploy.flow")]
        #expect(try FlowCatalog.resolve(flowArgument: "deploy", entries: entries).id == "/lib/deploy.flow")
        #expect(try FlowCatalog.resolve(flowArgument: "FIX github ISSUE", entries: entries).file == nil)
        #expect(throws: LaunchArgumentError.noFlowNamed("zzz")) { _ = try FlowCatalog.resolve(flowArgument: "zzz", entries: entries) }
    }

    @Test func flowNameAmbiguous() {
        let entries = [entry("Deploy", "/lib/a.flow"), entry("deploy", "/repo/.flows/b.flow")]
        #expect(throws: LaunchArgumentError.ambiguousFlow("Deploy", ["/lib/a.flow", "/repo/.flows/b.flow"])) {
            _ = try FlowCatalog.resolve(flowArgument: "Deploy", entries: entries)
        }
        let text = LaunchArgumentError.ambiguousFlow("Deploy", ["/lib/a.flow", "/repo/.flows/b.flow"]).localizedDescription
        #expect(text.contains("/lib/a.flow") && text.contains("/repo/.flows/b.flow"))
    }

    @Test func positionalFillsFirstField() throws {
        let fields = [LaunchField(name: "repo", kind: .repo), LaunchField(name: "issue", kind: .githubIssue),
                      LaunchField(name: "env", kind: .text)]
        let v = try LaunchArguments.values(fields: fields, positional: "42", sets: [("env", "prod")])
        #expect(v == ["issue": "42", "env": "prod"])
        #expect(throws: LaunchArgumentError.noFieldForValue) {
            _ = try LaunchArguments.values(fields: [LaunchField(name: "repo", kind: .repo)], positional: "1", sets: [])
        }
    }

    @Test func repoMismatchForFixedFlow() async throws {
        let h = try RunEngineTests.Harness()
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID().uuidString)")
        let flow = Flow(name: "f", nodes: [
            Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: .fixed(path: h.repo.url.path))), position: Point(x: 0, y: 0))
        ], wires: [])
        do {
            _ = try await h.engine.launch(flow: flow, location: .builtin, values: ["repo": other.path])
            Issue.record("expected repoMismatch")
        } catch let e as RunEngineError {
            #expect(e == .repoMismatch(expected: h.repo.url))
            #expect(e.localizedDescription == "this flow always runs on \(h.repo.url.path)")
        }
    }

    @Test func initFlowWritesThisRepo() throws {
        let root = URL(fileURLWithPath: "/tmp/some-repo", isDirectory: true)
        let (flow, _) = FlowCatalog.prepareForSave(BuiltinFlows.fixGitHubIssue,
                                                   destination: .repo(root: root, file: root.appendingPathComponent(".flows/fix-issue.flow")),
                                                   origin: nil)
        var modes: [RepoMode] = []
        for n in flow.nodes { if case .repo(let c) = n.kind { modes.append(c.mode) } }
        #expect(modes == [.thisRepo])
        #expect(throws: Never.self) { _ = try flow.launchFields(location: .repo(root: root, file: root.appendingPathComponent(".flows/fix-issue.flow"))) }
    }
}
