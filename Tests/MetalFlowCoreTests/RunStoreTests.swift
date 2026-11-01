import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct RunStoreTests {
    func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mf-runstore-\(UUID().uuidString)")
    }

    func makeRun(created: TimeInterval = 1_000_000, status: RunStatus = .running,
                 nodes: [NodeKey: NodeRun] = [:]) -> Run {
        let flow = Flow(name: "f", nodes: [
            Node(id: "plan", title: "Plan", kind: .repo(RepoConfig(mode: .thisRepo)), position: Point(x: 0, y: 0)),
            Node(id: "implement", title: "Impl", kind: .repo(RepoConfig(mode: .thisRepo)), position: Point(x: 1, y: 0)),
        ], wires: [])
        return Run(flow: flow, title: "t", repo: URL(fileURLWithPath: "/tmp/repo"),
                   baseBranch: "main", branch: "flow/1-x", worktree: URL(fileURLWithPath: "/tmp/wt"),
                   inputs: ["issue": "1"], createdAt: Date(timeIntervalSince1970: created),
                   status: status, nodes: nodes,
                   lanes: [Lane(id: "a", model: "m", branch: "b", worktree: URL(fileURLWithPath: "/tmp/l"))],
                   recommendation: "a")
    }

    @Test func saveAndLoadRoundTrip() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunStore(root: root)
        var nr = NodeRun(state: .needsYou(.pickWinner(recommended: "a", allGatesFailed: false)))
        nr.appendLog("hi")
        let run = makeRun(status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .succeeded, output: "out"),
            NodeKey(node: "implement", lane: "b"): nr,
        ])
        try store.save(run)
        let json = try String(contentsOf: root.appendingPathComponent("runs/\(run.id.rawValue).json"), encoding: .utf8)
        #expect(json.contains("\"implement@b\""))
        let loaded = try store.loadAll()
        #expect(loaded == [run])
        #expect(loaded[0].needsYou.count == 1)
        try store.delete(run.id)
        #expect(try store.loadAll().isEmpty)
    }

    @Test func loadMarksRunningAsInterrupted() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunStore(root: root)
        let run = makeRun(status: .running, nodes: [NodeKey(node: "plan"): NodeRun(state: .running)])
        try store.save(run)
        let loaded = try store.loadAll()
        #expect(loaded[0].nodes[NodeKey(node: "plan")]?.state == .interrupted)
        #expect(loaded[0].status == .needsYou)
    }

    @Test func loadAllSortsNewestFirst() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunStore(root: root)
        let old = makeRun(created: 100), new = makeRun(created: 200)
        try store.save(old); try store.save(new)
        #expect(try store.loadAll().map(\.id) == [new.id, old.id])
    }

    @Test func knownReposAreDeduplicated() throws {
        let root = tempRoot()
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("mf-repo-\(UUID().uuidString)")
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("mf-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
        defer { for u in [root, repo, link] { try? FileManager.default.removeItem(at: u) } }
        let store = RunStore(root: root)
        try store.addKnownRepo(repo)
        try store.addKnownRepo(link)
        try store.addKnownRepo(repo.appendingPathComponent("../\(repo.lastPathComponent)"))
        #expect(store.knownRepos().count == 1)
        #expect(RunStore(root: root).knownRepos().count == 1)
        #expect(store.worktreesDirectory == root.appendingPathComponent("worktrees"))
    }

    @Test func corruptRunFileIsSkipped() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunStore(root: root)
        let run = makeRun()
        try store.save(run)
        try Data("garbage".utf8).write(to: root.appendingPathComponent("runs/x.json"))
        #expect(try store.loadAll().map(\.id) == [run.id])
    }

    @Test func logKeepsLastFifty() {
        var n = NodeRun()
        for i in 0..<60 { n.appendLog("\(i)") }
        #expect(n.log.count == 50 && n.log.first == "10" && n.log.last == "59")
    }

    @Test func nodeKeyParsing() {
        #expect(NodeKey(description: "implement@b") == NodeKey(node: "implement", lane: "b"))
        #expect(NodeKey(description: "plan") == NodeKey(node: "plan"))
        #expect(NodeKey(node: "x", lane: "a").description == "x@a")
    }

    @Test func nodeKeyRejectsInvalidAndRoundTrips() {
        #expect(NodeKey(description: "a@b@c") == nil)
        #expect(NodeKey(description: "") == nil)
        #expect(NodeKey(description: "has space") == nil)
        for k in [NodeKey(node: "plan"), NodeKey(node: "impl-1_x", lane: "b")] {
            #expect(NodeKey(description: k.description) == k)
        }
    }

    @Test func sameSecondRunsKeepOrder() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunStore(root: root)
        let old = makeRun(created: 100.25), new = makeRun(created: 100.75)
        try store.save(old); try store.save(new)
        #expect(try store.loadAll().map(\.id) == [new.id, old.id])
    }

    @Test func needsYouIsOrderedByFlowIndexThenLane() {
        let ask = NodeRun(state: .needsYou(.question("q")))
        let run = makeRun(nodes: [
            NodeKey(node: "implement", lane: "b"): ask,
            NodeKey(node: "implement", lane: "a"): ask,
            NodeKey(node: "plan"): ask,
            NodeKey(node: "implement"): NodeRun(state: .running),
        ])
        #expect(run.needsYou.map(\.0.description) == ["plan", "implement@a", "implement@b"])
    }
}
