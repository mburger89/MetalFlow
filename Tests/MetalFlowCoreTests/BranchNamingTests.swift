import Testing
@testable import MetalFlowCore

@Suite struct BranchNamingTests {
    @Test func slugAndUniqueBranch() {
        #expect(BranchNaming.slug("Fix: crash / on ✨ empty graph!!") == "fix-crash-on-empty-graph")
        #expect(BranchNaming.slug(String(repeating: "abcd ", count: 40)).count <= 30)
        #expect(!BranchNaming.slug(String(repeating: "abcd ", count: 40)).hasSuffix("-"))
        #expect(BranchNaming.slug("") == "run")
        #expect(BranchNaming.runBranch(issue: 42, title: "Undo", existing: ["flow/42-undo"]) == "flow/42-undo-2")
        #expect(BranchNaming.runBranch(issue: 42, title: "Undo", existing: ["flow/42-undo", "flow/42-undo-2"]) == "flow/42-undo-3")
        #expect(BranchNaming.runBranch(issue: nil, title: "Undo", existing: []) == "flow/undo")
        #expect(BranchNaming.laneBranch(run: "flow/42-undo", lane: "a") == "flow/42-undo--a")
    }

    @Test func runBranchSkipsNamesWithLeftoverLaneBranches() {
        #expect(BranchNaming.runBranch(issue: 42, title: "Undo", existing: ["flow/42-undo--a"]) == "flow/42-undo-2")
        #expect(BranchNaming.runBranch(issue: 42, title: "Undo", existing: ["flow/42-undo-2--b", "flow/42-undo"]) == "flow/42-undo-3")
    }
}
