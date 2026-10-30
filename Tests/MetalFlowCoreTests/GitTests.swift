import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct GitTests {
    let git = Git(runner: ProcessRunner(resolver: ExecutableResolver(searchPath: ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"])))

    @Test func worktreeIsIsolatedFromCheckout() async throws {
        let repo = try TempRepo()
        let wt = repo.worktreePath("wt")
        try await git.addWorktree(repo: repo.url, path: wt, newBranch: "flow/x", from: "main")
        try repo.write("new.txt", "x", in: wt)
        #expect(try await git.isDirty(worktree: repo.url) == false)
        #expect(try await git.isDirty(worktree: wt))
        #expect(try await git.branches(repo: repo.url).contains("flow/x"))
        try await git.removeWorktree(repo: repo.url, path: wt)
        try await git.deleteBranch(repo: repo.url, name: "flow/x")
        #expect(try await git.branches(repo: repo.url) == ["main"])
    }

    @Test func commitAllReportsNothingToCommit() async throws {
        let repo = try TempRepo()
        #expect(try await git.commitAll(worktree: repo.url, message: "none") == false)
        try repo.write("a.txt", "a")
        #expect(try await git.commitAll(worktree: repo.url, message: "add a"))
        #expect(try await git.isDirty(worktree: repo.url) == false)
        #expect(try await git.currentBranch(repo: repo.url) == "main")
    }

    @Test func diffStatCountsLines() async throws {
        let repo = try TempRepo()
        let wt = repo.worktreePath("wt")
        try await git.addWorktree(repo: repo.url, path: wt, newBranch: "flow/d", from: "main")
        try repo.write("a.txt", "1\n2\n3\n", in: wt)
        try repo.write("README.md", "changed\n", in: wt)
        _ = try await git.commitAll(worktree: wt, message: "change")
        let stat = try await git.diffStat(worktree: wt, base: "main")
        #expect(stat.added == 4)
        #expect(stat.removed == 1)
        #expect(try await git.diff(worktree: wt, base: "main").contains("+changed"))
    }

    @Test func checkoutFindsMainRepo() async throws {
        let repo = try TempRepo()
        
        #expect(try await git.checkout(of: "main", repo: repo.url) == repo.url)
        #expect(try await git.checkout(of: "nope", repo: repo.url) == nil)
    }

    @Test func mergeWhenBaseNotCheckedOut() async throws {
        let repo = try TempRepo()
        try repo.git(["branch", "release"])
        let wt = repo.worktreePath("wt")
        try await git.addWorktree(repo: repo.url, path: wt, newBranch: "flow/m", from: "release")
        try repo.write("m.txt", "m", in: wt)
        _ = try await git.commitAll(worktree: wt, message: "m")
        let before = try repo.git(["worktree", "list"]).split(separator: "\n").count
        let result = try await git.merge(repo: repo.url, branch: "flow/m", into: "release", message: "Merge m")
        let head = try repo.git(["rev-parse", "release"]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(result == .merged(commit: head))
        #expect(try repo.git(["worktree", "list"]).split(separator: "\n").count == before)
    }

    @Test func mergeIntoCheckoutAndConflict() async throws {
        let repo = try TempRepo()
        let wt = repo.worktreePath("wt")
        try await git.addWorktree(repo: repo.url, path: wt, newBranch: "flow/c", from: "main")
        try repo.write("README.md", "branch\n", in: wt)
        _ = try await git.commitAll(worktree: wt, message: "b")
        try repo.write("README.md", "main\n")
        try repo.commit("m")
        let result = try await git.merge(repo: repo.url, branch: "flow/c", into: "main", message: "Merge")
        #expect(result == .conflict(files: ["README.md"]))
        #expect(try await git.isDirty(worktree: repo.url) == false)
    }
}
