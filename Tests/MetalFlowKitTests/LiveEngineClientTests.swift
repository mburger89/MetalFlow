import Foundation
import Testing
import MetalFlowCore
@testable import MetalFlowKit

@Suite struct LiveEngineClientTests {
    @Test func constructionDoesNotWaitForTheEngine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mf-\(UUID().uuidString)")
        let store = RunStore(root: root)
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        let built = Flag()
        let client = LiveEngineClient(store: store) {
            for await _ in gate { break }
            await built.set()
            let runner = ProcessRunner(resolver: ExecutableResolver(searchPath: []))
            return RunEngine(store: store, runner: runner, agent: ClaudeCLI(runner: runner),
                             issues: GitHubIssues(runner: runner))
        }
        // The builder is still blocked, yet the client exists and synchronous queries work.
        #expect(await built.value == false)
        #expect(client.flowCatalog().map(\.location) == [.builtin, .builtin], "an empty store lists only the built-in flows")
        #expect(client.knownRepos().isEmpty)

        release.yield()
        let runs = try await client.restore()
        #expect(runs.isEmpty)
        #expect(await built.value)
    }

    /// The real engine's `reload` joined to `AppModel.apply`: a run whose driver died after the last save the app saw.
    @MainActor
    @Test func aRunWhoseDriverDiedShowsCutShortThroughTheRealEngine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RunStore(root: root)
        let run = makeRun("theirs", status: .running, nodes: [NodeKey(node: "plan"): NodeRun(state: .running)])
        try store.save(run)
        let lock = try #require(store.tryLock(run.id))
        let client = LiveEngineClient(store: store) {
            let runner = ProcessRunner(resolver: ExecutableResolver(searchPath: []))
            return RunEngine(store: store, runner: runner, agent: ClaudeCLI(runner: runner),
                             issues: GitHubIssues(runner: runner))
        }
        let model = AppModel(client: client, notifier: NoopNotifier())
        let running = Task { await model.start() }
        defer { running.cancel() }
        await model.waitUntilReady()
        #expect(model.runs[run.id]?.status == .running)
        #expect(model.runningElsewhere == [run.id], "its lock is held")

        // The driver dies: its lock goes, and it saved nothing more.
        lock.release()
        await model.refreshElsewhere()
        let shown = try #require(model.runs[run.id])
        #expect(shown.revision == run.revision)
        #expect(shown.status == .needsYou)
        #expect(shown.nodes[NodeKey(node: "plan")]?.state == .interrupted)
        #expect(model.runningElsewhere.isEmpty)
        #expect(store.load(run.id)?.status == .running, "nothing was saved")
    }
}

private actor Flag {
    var value = false
    func set() { value = true }
}
