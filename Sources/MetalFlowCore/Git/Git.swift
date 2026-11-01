import Foundation

/// Outcome of merging a branch into a target branch.
public enum MergeResult: Equatable, Sendable {
    /// The merge succeeded; `commit` is the new HEAD of the target branch.
    case merged(commit: String)
    /// The target branch is checked out at `checkout` with uncommitted changes, so nothing was merged.
    case blockedDirty(checkout: URL)
    /// The merge conflicted in these files and was aborted.
    case conflict(files: [String])
    /// Nothing was merged: the flow opens a pull request for the chosen candidate, and the run carries on to do so.
    case handedToPullRequest
}

/// Failures of git operations that are not ordinary merge conflicts.
public enum GitError: Error, Equatable {
    /// The merge failed for a reason other than a conflict (missing branch, hook, identity, untracked files in the way).
    case mergeFailed(stderr: String)
    /// A conflicted merge could not be aborted, so `checkout` is still mid-merge.
    case abortFailed(checkout: URL, stderr: String)
    /// `git push` failed (no remote, not authenticated, network down, rejected).
    case pushFailed(stderr: String)
}

extension GitError: LocalizedError {
    /// A readable message including git's stderr.
    public var errorDescription: String? {
        switch self {
        case .mergeFailed(let stderr):
            return "git merge failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .abortFailed(let checkout, let stderr):
            return "git merge --abort failed; \(checkout.path) may still be mid-merge: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .pushFailed(let stderr):
            return "git push failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// How many commits of a base branch are missing from its counterpart on `origin`.
public enum UnpublishedCommits: Equatable, Sendable {
    /// `origin/<base>` exists and `<base>` is this many commits ahead of it (possibly 0).
    case count(Int)
    /// There is no `origin/<base>` to compare with.
    case remoteBranchMissing
    /// The comparison itself failed for another reason.
    case unknown
}

/// Git operations used for run and candidate worktrees.
public struct Git: Sendable {
    private let runner: CommandRunner

    /// Creates a Git facade over a command runner.
    public init(runner: CommandRunner) {
        self.runner = runner
    }

    private func command(_ path: URL, _ args: [String]) -> Command {
        Command(executable: "git", arguments: ["-C", path.path] + args, environment: ["GIT_TERMINAL_PROMPT": "0"])
    }

    @discardableResult
    private func run(_ path: URL, _ args: [String]) async throws -> String {
        try await runner.check(command(path, args)).stdout
    }

    /// The branch currently checked out in `repo`; returns "HEAD" when detached.
    public func currentBranch(repo: URL) async throws -> String {
        try await run(repo, ["rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All local branch names.
    public func branches(repo: URL) async throws -> Set<String> {
        let out = try await run(repo, ["for-each-ref", "--format=%(refname:short)", "refs/heads"])
        return Set(out.split(whereSeparator: \.isNewline).map(String.init))
    }

    /// Adds a worktree at `path` on a new branch `newBranch` started from `from`.
    public func addWorktree(repo: URL, path: URL, newBranch: String, from: String) async throws {
        try await run(repo, ["worktree", "add", "-b", newBranch, path.path, from])
    }

    /// Adds a worktree at `path` that checks out the existing branch `existingBranch`.
    public func addWorktree(repo: URL, path: URL, existingBranch: String) async throws {
        try await run(repo, ["worktree", "add", path.path, existingBranch])
    }

    /// Force-removes the worktree at `path`.
    public func removeWorktree(repo: URL, path: URL) async throws {
        try await run(repo, ["worktree", "remove", "--force", path.path])
    }

    /// True when `name` is a valid branch name (`git check-ref-format --branch` accepts it unchanged).
    public func isValidBranchName(_ name: String) async throws -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-") else { return false }
        let result = try await runner.run(Command(
            executable: "git", arguments: ["check-ref-format", "--branch", name], environment: ["GIT_TERMINAL_PROMPT": "0"]))
        return result.succeeded && result.stdout.trimmingCharacters(in: .newlines) == name
    }

    /// Creates a local branch `name` at `startPoint` without checking it out.
    public func createBranch(repo: URL, name: String, at startPoint: String) async throws {
        try await run(repo, ["branch", name, startPoint])
    }

    /// Removes administrative records of worktrees whose directories are gone.
    public func pruneWorktrees(repo: URL) async throws {
        try await run(repo, ["worktree", "prune"])
    }

    /// Force-deletes a local branch.
    public func deleteBranch(repo: URL, name: String) async throws {
        try await run(repo, ["branch", "-D", name])
    }

    /// Stages and commits everything; returns false when there was nothing to commit.
    public func commitAll(worktree: URL, message: String) async throws -> Bool {
        guard try await isDirty(worktree: worktree) else { return false }
        try await run(worktree, ["add", "-A"])
        try await run(worktree, ["commit", "-m", message])
        return true
    }

    /// Committed changes of the worktree's HEAD relative to `base`, as a unified diff.
    public func diff(worktree: URL, base: String) async throws -> String {
        try await run(worktree, ["diff", base, "HEAD"])
    }

    /// Lines added and removed between `base` and HEAD; binary files count as 0.
    public func diffStat(worktree: URL, base: String) async throws -> (added: Int, removed: Int) {
        let out = try await run(worktree, ["diff", "--numstat", base, "HEAD"])
        var added = 0, removed = 0
        for line in out.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            added += Int(parts[0]) ?? 0
            removed += Int(parts[1]) ?? 0
        }
        return (added, removed)
    }

    /// True when the worktree has uncommitted or untracked changes.
    public func isDirty(worktree: URL) async throws -> Bool {
        let out = try await run(worktree, ["status", "--porcelain"])
        return !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The path of the worktree that has `branch` checked out, if any.
    public func checkout(of branch: String, repo: URL) async throws -> URL? {
        let out = try await run(repo, ["worktree", "list", "--porcelain"])
        var path: String?
        for line in out.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line == "branch refs/heads/\(branch)", let path {
                return URL(fileURLWithPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path, isDirectory: true)
            } else if line.isEmpty {
                path = nil
            }
        }
        return nil
    }

    /// Pushes `branch` to `origin` and makes it track the remote branch. Never forces.
    public func push(repo: URL, branch: String) async throws {
        let result = try await runner.run(command(repo, ["push", "-u", "origin", branch]))
        guard result.succeeded else { throw GitError.pushFailed(stderr: result.stderr) }
    }

    /// How far `base` is ahead of `origin/<base>`, going by what is already fetched. Never throws.
    public func unpublishedCommits(repo: URL, base: String) async -> UnpublishedCommits {
        let list = try? await runner.run(command(repo, ["rev-list", "--count", "origin/\(base)..\(base)"]))
        if let list, list.succeeded, let count = Int(list.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .count(count)
        }
        // The count failed: either there is no origin/<base>, or something else is wrong.
        let probe = try? await runner.run(command(repo, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(base)"]))
        if let probe, !probe.succeeded { return .remoteBranchMissing }
        return .unknown
    }

    /// Merges `branch` into `target` with a merge commit. Uses the target's checkout when it has one,
    /// otherwise a temporary worktree that is always removed.
    ///
    /// The whole sequence runs in an unstructured task, so once started it completes (or is verifiably aborted)
    /// even if the caller is cancelled.
    public func merge(repo: URL, branch: String, into target: String, message: String) async throws -> MergeResult {
        try await Task { try await mergeSequence(repo: repo, branch: branch, into: target, message: message) }.value
    }

    private func mergeSequence(repo: URL, branch: String, into target: String, message: String) async throws -> MergeResult {
        if let co = try await checkout(of: target, repo: repo) {
            if try await isDirty(worktree: co) { return .blockedDirty(checkout: co) }
            return try await mergeIn(co, branch: branch, message: message)
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("metalflow-merge-\(UUID().uuidString)")
        try await run(repo, ["worktree", "add", tmp.path, target])
        let result: MergeResult
        do {
            result = try await mergeIn(tmp, branch: branch, message: message)
        } catch {
            await cleanup(repo: repo, tmp: tmp)
            throw error
        }
        await cleanup(repo: repo, tmp: tmp)
        return result
    }

    /// Cleanup runs unstructured so a cancelled caller still removes the temporary worktree.
    private func cleanup(repo: URL, tmp: URL) async {
        await Task {
            _ = try? await runner.run(command(repo, ["worktree", "remove", "--force", tmp.path]))
            try? FileManager.default.removeItem(at: tmp)
            _ = try? await runner.run(command(repo, ["worktree", "prune"]))
        }.value
    }

    private func mergeIn(_ dir: URL, branch: String, message: String) async throws -> MergeResult {
        let result = try await runner.run(command(dir, ["merge", "--no-ff", "-m", message, branch]))
        if result.succeeded {
            let sha = try await run(dir, ["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
            return .merged(commit: sha)
        }
        return try await handleFailedMerge(dir, stderr: result.stderr)
    }

    private func handleFailedMerge(_ dir: URL, stderr: String) async throws -> MergeResult {
        let hadMergeHead = (try? await runner.run(command(dir, ["rev-parse", "-q", "--verify", "MERGE_HEAD"])))?.succeeded ?? false
        let names = (try? await runner.run(command(dir, ["diff", "--name-only", "--diff-filter=U", "-z"])))?.stdout ?? ""
        let abort = try? await runner.run(command(dir, ["merge", "--abort"]))
        let stillMerging = (try? await runner.run(command(dir, ["rev-parse", "-q", "--verify", "MERGE_HEAD"])))?.succeeded ?? true
        if stillMerging {
            throw GitError.abortFailed(checkout: dir, stderr: abort?.stderr ?? "")
        }
        let files = names.split(separator: "\0").map(String.init)
        guard hadMergeHead, !files.isEmpty else { throw GitError.mergeFailed(stderr: stderr) }
        return .conflict(files: files)
    }
}
