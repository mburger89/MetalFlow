import Foundation
import Testing
import MetalFlowCore
@testable import mflow

@Suite struct FormattingTests {
    @Test func needsYouText() {
        #expect(mflow.needsYouText(.question("why?")) == "question: why?")
        #expect(mflow.needsYouText(.deniedTools(["Bash", "Edit"])) == "denied tools: Bash, Edit")
        #expect(mflow.needsYouText(.pickWinner(recommended: nil, allGatesFailed: false)) == "pick a winner")
        #expect(mflow.needsYouText(.pickWinner(recommended: "b", allGatesFailed: true))
            == "pick a winner, recommended b, all gates failed")
        #expect(mflow.needsYouText(.pickWinner(recommended: nil, allGatesFailed: true)) == "pick a winner, all gates failed")
    }

    @Test func stateText() {
        #expect(mflow.stateText(.waiting) == "waiting")
        #expect(mflow.stateText(.running) == "running")
        #expect(mflow.stateText(.succeeded) == "succeeded")
        #expect(mflow.stateText(.failed("boom")) == "failed: boom")
        #expect(mflow.stateText(.interrupted) == "interrupted")
        #expect(mflow.stateText(.cancelled) == "cancelled")
        #expect(mflow.stateText(.needsYou(.question("q"))) == "needs you (question: q)")
    }

    @Test func statusText() {
        #expect(mflow.statusText(.running) == "running")
        #expect(mflow.statusText(.needsYou) == "needs you")
        #expect(mflow.statusText(.merged("b")) == "merged (b)")
        #expect(mflow.statusText(.discarded) == "discarded")
        #expect(mflow.statusText(.failed("x")) == "failed: x")
        #expect(mflow.statusText(.cancelled) == "cancelled")
        #expect(mflow.statusText(.completed) == "completed")
    }

    @Test func gateText() {
        #expect(mflow.gateText(true) == "gate passed")
        #expect(mflow.gateText(false) == "gate failed")
        #expect(mflow.gateText(nil) == "gate pending")
    }

    @Test func mergeResultText() {
        #expect(mflow.mergeResultText(.merged(commit: "abc")) == "merged as abc")
        #expect(mflow.mergeResultText(.conflict(files: ["a.swift", "b.swift"])) == "not merged: conflicts in a.swift, b.swift")
        let dirty = mflow.mergeResultText(.blockedDirty(checkout: URL(fileURLWithPath: "/x/y")))
        #expect(dirty == "not merged: the base branch is checked out at /x/y with uncommitted changes")
    }
}
