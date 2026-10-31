import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct RunEngineLaneDiffTests {
    typealias Harness = RunEngineTests.Harness

    @Test func laneDiffShowsLaneChanges() async throws {
        let h = try Harness()
        let id = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
        _ = await h.settled(id)
        let diff = await h.engine.laneDiff(id, lane: "a")
        #expect(diff.contains("+ok"))
        #expect(diff.contains("ok.txt"))
    }

    @Test func laneDiffOfUnknownLaneIsEmpty() async throws {
        let h = try Harness()
        let id = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
        _ = await h.settled(id)
        #expect(await h.engine.laneDiff(id, lane: "zzz") == "")
        #expect(await h.engine.laneDiff(RunID(), lane: "a") == "")
    }
}
