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
        #expect(client.flows(in: root).isEmpty)
        #expect(client.knownRepos().isEmpty)

        release.yield()
        let runs = try await client.restore()
        #expect(runs.isEmpty)
        #expect(await built.value)
    }
}

private actor Flag {
    var value = false
    func set() { value = true }
}
