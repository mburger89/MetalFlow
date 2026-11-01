import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct OpenPRFlowTests {
    private func node(_ id: String, _ kind: NodeKind) -> Node {
        Node(id: NodeID(rawValue: id), title: id, kind: kind, position: Point(x: 0, y: 0))
    }

    /// The built-in flow with an Open PR node after its pick.
    private func prFlow(draft: Bool = true) -> Flow {
        var flow = BuiltinFlows.fixGitHubIssue
        flow.nodes.append(node("openpr", .openPR(OpenPRConfig(draft: draft))))
        flow.wires.append(Wire(from: "pick", to: "openpr", input: "approval"))
        return flow
    }

    // MARK: Validation

    @Test func openPRWithoutAPickBeforeItIsRejected() {
        var flow = BuiltinFlows.fixGitHubIssue
        flow.nodes.append(node("openpr", .openPR(OpenPRConfig())))
        #expect(throws: FlowError.openPRWithoutPick("openpr")) { try flow.validate() }
        #expect(FlowError.openPRWithoutPick("openpr").errorDescription == "Open PR needs a You pick before it.")
        #expect(flow.message(for: .openPRWithoutPick("openpr")) == "Open PR needs a You pick before it.")
    }

    @Test func aJudgeIsNotAPick() {
        var flow = BuiltinFlows.fixGitHubIssue
        flow.nodes.append(node("openpr", .openPR(OpenPRConfig())))
        flow.wires.append(Wire(from: "judge", to: "openpr", input: "x"))
        #expect(throws: FlowError.openPRWithoutPick("openpr")) { try flow.validate() }
    }

    @Test func aPickAfterTheOpenPRDoesNotCount() {
        var flow = BuiltinFlows.fixGitHubIssue
        flow.nodes.append(node("openpr", .openPR(OpenPRConfig())))
        flow.wires.append(Wire(from: "openpr", to: "pick", input: "x"))
        #expect(throws: FlowError.openPRWithoutPick("openpr")) { try flow.validate() }
    }

    @Test func twoOpenPRNodesAreRejected() {
        var flow = prFlow()
        flow.nodes.append(node("openpr2", .openPR(OpenPRConfig())))
        flow.wires.append(Wire(from: "pick", to: "openpr2", input: "approval"))
        #expect(throws: FlowError.multipleOpenPRs("openpr2")) { try flow.validate() }
        #expect(FlowError.multipleOpenPRs("openpr2").errorDescription == "A flow can have only one Open PR node.")
        #expect(flow.message(for: .multipleOpenPRs("openpr2")) == "A flow can have only one Open PR node.")
    }

    @Test func aValidFlowPassesAndTheNodeIsNotLaneScoped() throws {
        let plan = try prFlow().validate()
        #expect(plan.fanOut == "implement")
        #expect(plan.laneScoped == ["implement", "gate"])
        let order = plan.order
        #expect(try #require(order.firstIndex(of: "openpr")) > #require(order.firstIndex(of: "pick")))
    }

    @Test func thePickMayBeSeveralWiresUpstream() throws {
        var flow = BuiltinFlows.fixGitHubIssue
        flow.nodes.append(node("after", .shell(ShellConfig(command: "echo hi"))))
        flow.nodes.append(node("openpr", .openPR(OpenPRConfig())))
        flow.wires.append(Wire(from: "pick", to: "after", input: "x"))
        flow.wires.append(Wire(from: "after", to: "openpr", input: "y"))
        _ = try flow.validate()
    }

    @Test func theBuiltInFlowIsUnchanged() throws {
        let flow = BuiltinFlows.fixGitHubIssue
        #expect(!flow.hasOpenPR)
        #expect(flow.nodes.map(\.id.rawValue) == ["issue", "repo", "plan", "implement", "gate", "judge", "pick"])
        _ = try flow.validate()
    }

    // MARK: File format

    @Test func aSavedFlowWithNoOpenPRLoadsUnchanged() throws {
        let json = #"""
        {"formatVersion":1,"flow":{"name":"old","wires":[{"from":"a","to":"p","input":"x"}],"nodes":[
        {"id":"repo","title":"Repo","kind":{"repo":{}},"position":{"x":0,"y":0}},
        {"id":"p","title":"You pick","kind":{"pick":{}},"position":{"x":1,"y":1}}]}}
        """#
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("old.flow")
        try Data(json.utf8).write(to: url)
        let flow = try FlowFile.load(from: url)
        #expect(!flow.hasOpenPR)
        #expect(flow.node("p")?.kind == .pick)
    }

    @Test func aSavedRunWithNoPickedLaneLoads() throws {
        let url = try #require(Bundle.module.url(forResource: "preplan-run", withExtension: "json", subdirectory: "Fixtures"))
        let id = RunID()
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "__ID__", with: id.rawValue)
            .replacingOccurrences(of: "__REPO_URL__", with: "file:///tmp/repo/")
            .replacingOccurrences(of: "__WORKTREE_URL__", with: "file:///tmp/wt/")
            .replacingOccurrences(of: "__REPO__", with: "/tmp/repo")
        #expect(!text.contains("pickedLane"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runs"), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: root.appendingPathComponent("runs/\(id.rawValue).json"))
        let runs = try RunStore(root: root).loadAll()
        #expect(runs.map(\.id) == [id])
        #expect(runs[0].pickedLane == nil)
    }

    @Test func draftSurvivesARoundTrip() throws {
        for draft in [true, false] {
            let flow = prFlow(draft: draft)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("pr.flow")
            try FlowFile.save(flow, to: url)
            #expect(try FlowFile.load(from: url) == flow)
            #expect(try FlowFile.load(from: url).node("openpr")?.kind == .openPR(OpenPRConfig(draft: draft)))
            #expect(try String(contentsOf: url, encoding: .utf8).contains("\"formatVersion\" : 1"))
        }
    }

    @Test func aMissingDraftKeyMeansDraft() throws {
        let kind = try JSONDecoder().decode(NodeKind.self, from: Data(#"{"openPR":{"_0":{}}}"#.utf8))
        #expect(kind == .openPR(OpenPRConfig(draft: true)))
        #expect(OpenPRConfig().draft)
    }

    @Test func pickedLaneAndPrStatusRoundTripThroughTheStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunStore(root: root)
        let plain = Run(flow: prFlow(), title: "t", repo: URL(fileURLWithPath: "/tmp/r"), baseBranch: "main",
                        branch: "flow/x", worktree: URL(fileURLWithPath: "/tmp/w"))
        var picked = plain
        picked.id = RunID()
        picked.pickedLane = "b"
        picked.status = .prOpened("b", url: "https://github.com/o/r/pull/3")
        try store.save(plain)
        try store.save(picked)
        let loaded = Dictionary(uniqueKeysWithValues: try store.loadAll().map { ($0.id, $0) })
        #expect(loaded[plain.id]?.pickedLane == nil)
        #expect(loaded[picked.id]?.pickedLane == "b")
        #expect(loaded[picked.id]?.status == .prOpened("b", url: "https://github.com/o/r/pull/3"))
        // A run that never picked saves no new key, so an older build reads it as before.
        let json = try String(contentsOf: root.appendingPathComponent("runs/\(plain.id.rawValue).json"), encoding: .utf8)
        #expect(!json.contains("pickedLane"))
    }
}
