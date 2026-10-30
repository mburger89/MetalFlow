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
        let parents = try repo.git(["rev-list", "--parents", "-n1", "release"]).split(separator: " ")
        #expect(parents.count == 3)
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
        let headBefore = try repo.git(["rev-parse", "HEAD"])
        let result = try await git.merge(repo: repo.url, branch: "flow/c", into: "main", message: "Merge")
        #expect(result == .conflict(files: ["README.md"]))
        #expect(try repo.git(["rev-parse", "HEAD"]) == headBefore)
        #expect(try await git.isDirty(worktree: repo.url) == false)
    }

    private func conflictingBranch(_ repo: TempRepo, target: String) async throws {
        let wt = repo.worktreePath("wt-\(UUID().uuidString)")
        try await git.addWorktree(repo: repo.url, path: wt, newBranch: "flow/k", from: "main")
        try repo.write("README.md", "branch\n", in: wt)
        _ = try await git.commitAll(worktree: wt, message: "b")
        try await git.removeWorktree(repo: repo.url, path: wt)
        if target == "main" {
            try repo.write("README.md", "main\n")
            try repo.commit("m")
        } else {
            try repo.git(["checkout", "-q", "-b", target, "main"])
            try repo.write("README.md", "other\n")
            try repo.commit("o")
            try repo.git(["checkout", "-q", "main"])
        }
    }

    @Test func conflictLeavesTargetUnchanged() async throws {
        for target in ["main", "release"] {
            let repo = try TempRepo()
            try await conflictingBranch(repo, target: target)
            let sha = try repo.git(["rev-parse", target])
            let status = try repo.git(["status", "--porcelain"])
            let result = try await git.merge(repo: repo.url, branch: "flow/k", into: target, message: "Merge")
            #expect(result == .conflict(files: ["README.md"]))
            #expect(try repo.git(["rev-parse", target]) == sha)
            #expect(try repo.git(["status", "--porcelain"]) == status)
            #expect(try repo.git(["worktree", "list"]).split(separator: "\n").count == 1)
            #expect(try repo.gitStatus(["rev-parse", "-q", "--verify", "MERGE_HEAD"]).exit != 0)
        }
    }

    @Test func mergeOfMissingBranchThrows() async throws {
        let repo = try TempRepo()
        do {
            _ = try await git.merge(repo: repo.url, branch: "nope", into: "main", message: "Merge")
            Issue.record("expected throw")
        } catch let error as GitError {
            guard case .mergeFailed = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    @Test func cancelledMergeStillCompletes() async throws {
        let repo = try TempRepo()
        try repo.git(["branch", "release"])
        let wt = repo.worktreePath("wt")
        try await git.addWorktree(repo: repo.url, path: wt, newBranch: "flow/z", from: "release")
        try repo.write("z.txt", "z", in: wt)
        _ = try await git.commitAll(worktree: wt, message: "z")
        let git = self.git
        let url = repo.url
        let task = Task { try await git.merge(repo: url, branch: "flow/z", into: "release", message: "Merge z") }
        task.cancel()
        let result = try await task.value
        guard case .merged = result else { Issue.record("expected merged, got \(result)"); return }
        #expect(try repo.gitStatus(["rev-parse", "-q", "--verify", "MERGE_HEAD"]).exit != 0)
        #expect(try repo.git(["worktree", "list"]).split(separator: "\n").count == 2)
    }
}
