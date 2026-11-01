import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct RunEngineOpenPRTests {
    typealias Harness = RunEngineTests.Harness

    static let prURL = "https://github.com/acme/widgets/pull/12"
    static let node = NodeKey(node: "openpr")

    // MARK: Helpers

    /// The harness flow with an Open PR node after the pick.
    func prFlow(_ h: Harness, draft: Bool = true, textInput: Bool = false) -> Flow {
        var flow = h.flow()
        if textInput, let i = flow.nodes.firstIndex(where: { $0.id == "issue" }) {
            flow.nodes[i].kind = .flowInput(FlowInputConfig(name: "issue", source: .text))
        }
        flow.nodes.append(Node(id: "openpr", title: "Open PR", kind: .openPR(OpenPRConfig(draft: draft)),
                               position: Point(x: 1200, y: 330)))
        flow.wires.append(Wire(from: "pick", to: "openpr", input: "approval"))
        return flow
    }

    /// Answers `git push` as a success and `gh pr create` with `prURL`.
    func stubSuccess(_ h: Harness) {
        h.hooks.stubGit("push")
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 0, stdout: "\n\(Self.prURL)\n\n", stderr: ""))
    }

    func launchToPick(_ h: Harness, _ flow: Flow, issue: String = "7") async throws -> RunID {
        let id = try await h.engine.launch(flow: flow, location: .builtin, values: ["issue": issue, "repo": h.repo.url.path])
        _ = await h.settled(id)
        await h.engine.waitForPass(id)
        return id
    }

    func pick(_ h: Harness, _ id: RunID, _ lane: LaneID = "b") async throws -> Run {
        let result = try await h.engine.pick(id, lane: lane)
        #expect(result == .handedToPullRequest)
        await h.engine.waitUntilSettled(id)
        return try #require(await h.engine.run(id))
    }

    func failure(_ run: Run, _ key: NodeKey = RunEngineOpenPRTests.node) -> String? {
        if case .failed(let message)? = run.nodes[key]?.state { return message }
        return nil
    }

    func mainHead(_ h: Harness) throws -> String {
        try h.repo.git(["rev-parse", "main"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func lane(_ run: Run, _ id: LaneID) throws -> Lane { try #require(run.lanes.first { $0.id == id }) }

    func localBranches(_ h: Harness) throws -> Set<String> {
        Set(try h.repo.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"])
            .split(whereSeparator: \.isNewline).map(String.init))
    }

    // MARK: Plain pick is unchanged

    @Test func aFlowWithoutOpenPRMergesAsBefore() async throws {
        let h = try Harness()
        h.hooks.stubGit("push", exit: 1, stderr: "must not push")
        let id = try await launchToPick(h, h.flow())
        let before = try mainHead(h)
        let result = try await h.engine.pick(id, lane: "b")
        guard case .merged = result else { Issue.record("expected a merge, got \(result)"); return }
        let run = try #require(await h.engine.run(id))
        #expect(run.status == .merged("b"))
        #expect(run.pickedLane == nil)
        #expect(try mainHead(h) != before)
        #expect(h.hooks.gitCalls("push").isEmpty)
        #expect(h.hooks.ghCalls().allSatisfy { $0.first != "pr" })
    }

    // MARK: Happy path

    @Test func pickingPushesTheBranchAndOpensADraftPullRequest() async throws {
        let h = try Harness()
        stubSuccess(h)
        let id = try await launchToPick(h, prFlow(h))
        let before = try mainHead(h)
        let launched = try #require(await h.engine.run(id))
        let b = try lane(launched, "b")
        #expect(b.model == "opus")
        #expect(b.gatePassed == true)

        let run = try await pick(h, id)

        #expect(h.hooks.calls.filter { $0.executable == "git" && DispatchedPush.isPush($0) }.map(\.arguments)
                == [["-C", run.repo.path, "push", "-u", "origin", b.branch]])
        let create = h.gh.calls.filter { $0.arguments.starts(with: ["pr", "create"]) }
        #expect(create.map(\.arguments) == [[
            "pr", "create", "--base", "main", "--head", b.branch, "--title", "Crash on launch",
            "--body", "Closes #7\n\nCandidate b (opus), tests passed, chosen in MetalFlow.", "--draft",
        ]])
        #expect(create.first?.workingDirectory == run.repo)
        #expect(run.pickedLane == "b")
        #expect(run.status == .prOpened("b", url: Self.prURL))
        #expect(run.nodes[Self.node]?.state == .succeeded)
        #expect(run.nodes[Self.node]?.output == Self.prURL)
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .succeeded)
        #expect(run.nodes[NodeKey(node: "pick")]?.output == "chose b")
        // Nothing was merged anywhere.
        #expect(h.hooks.gitCalls("merge").isEmpty)
        #expect(try mainHead(h) == before)
        #expect(run.keptBranches.contains(b.branch))
    }

    @Test func aNonDraftNodeOmitsTheDraftFlag() async throws {
        let h = try Harness()
        stubSuccess(h)
        let id = try await launchToPick(h, prFlow(h, draft: false))
        _ = try await pick(h, id, "a")
        let args = try #require(h.gh.calls.first { $0.arguments.starts(with: ["pr", "create"]) }).arguments
        #expect(!args.contains("--draft"))
        #expect(args.contains("Closes #7\n\nCandidate a (sonnet), tests passed, chosen in MetalFlow."))
    }

    @Test func bodyNamesTheGateOutcome() async throws {
        let h = try Harness()
        stubSuccess(h)
        let id = try await launchToPick(h, prFlow(h))
        let run = try await pick(h, id, "c")
        _ = run
        let body = try #require(h.gh.calls.first { $0.arguments.starts(with: ["pr", "create"]) }).arguments
        #expect(body.contains("Closes #7\n\nCandidate c (haiku), tests failed, chosen in MetalFlow."))
    }

    @Test func aTextInputRunHasNoClosesLine() async throws {
        let h = try Harness()
        stubSuccess(h)
        let id = try await launchToPick(h, prFlow(h, textInput: true), issue: "Speed up launch")
        let run = try await pick(h, id)
        #expect(run.title == "Speed up launch")
        let args = try #require(h.gh.calls.first { $0.arguments.starts(with: ["pr", "create"]) }).arguments
        #expect(args[args.firstIndex(of: "--title")! + 1] == "Speed up launch")
        #expect(args[args.firstIndex(of: "--body")! + 1] == "Candidate b (opus), tests passed, chosen in MetalFlow.")
        #expect(h.gh.calls.allSatisfy { !$0.arguments.contains { $0.contains("Closes") } })
    }

    @Test func aTextInputThatLooksLikeAnIssueTitleDoesNotClose() async throws {
        let h = try Harness()
        stubSuccess(h)
        let id = try await launchToPick(h, prFlow(h, textInput: true), issue: "#9 not really an issue")
        _ = try await pick(h, id)
        let args = try #require(h.gh.calls.first { $0.arguments.starts(with: ["pr", "create"]) }).arguments
        #expect(args[args.firstIndex(of: "--title")! + 1] == "not really an issue")
        #expect(!args[args.firstIndex(of: "--body")! + 1].contains("Closes"))
    }

    // MARK: Real push to a local bare origin

    @Test func theBranchReachesTheRemoteAndSurvivesCleanup() async throws {
        let h = try Harness()
        let bare = h.repo.worktreePath("origin.git")
        try h.repo.git(["init", "--bare", "-b", "main", bare.path])
        try h.repo.git(["remote", "add", "origin", bare.path])
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 0, stdout: Self.prURL + "\n", stderr: ""))
        let id = try await launchToPick(h, prFlow(h))
        let launched = try #require(await h.engine.run(id))
        let b = try lane(launched, "b")

        let run = try await pick(h, id)

        #expect(run.status == .prOpened("b", url: Self.prURL))
        let remote = try h.repo.git(["ls-remote", "--heads", "origin"])
        #expect(remote.contains("refs/heads/\(b.branch)"))
        let local = try localBranches(h)
        #expect(local.contains(b.branch), "the pushed branch survives locally")
        #expect(!local.contains(try lane(launched, "a").branch))
        #expect(!local.contains(try lane(launched, "c").branch))
        #expect(!local.contains(launched.branch))
        // The remote branch carries the candidate's commit.
        let remoteTip = try h.repo.git(["--git-dir", bare.path, "rev-parse", b.branch]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(remoteTip == (try h.repo.git(["rev-parse", b.branch])).trimmingCharacters(in: .whitespacesAndNewlines))
        // Worktrees are gone.
        for l in launched.lanes { #expect(!FileManager.default.fileExists(atPath: l.worktree.path)) }
        #expect(!FileManager.default.fileExists(atPath: launched.worktree.path))
        #expect(!FileManager.default.fileExists(atPath: h.store.worktreesDirectory.appendingPathComponent(id.rawValue).path))
        let worktrees = try h.repo.git(["worktree", "list", "--porcelain"]).split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("worktree ") }
        #expect(worktrees.count == 1)
        #expect(run.keptBranches == [b.branch])
    }

    // MARK: Failure and retry

    @Test func aFailedPushLeavesEverythingInPlaceAndRetrySucceeds() async throws {
        let h = try Harness()
        let stderr = "fatal: 'origin' does not appear to be a git repository\nfatal: Could not read from remote repository."
        h.hooks.stubGit("push", exit: 128, stderr: stderr)
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 0, stdout: Self.prURL + "\n", stderr: ""))
        let id = try await launchToPick(h, prFlow(h))
        let launched = try #require(await h.engine.run(id))
        let before = try mainHead(h)
        let branchesBefore = try localBranches(h)

        let run = try await pick(h, id)

        let message = try #require(failure(run))
        #expect(message.contains("does not appear to be a git repository"))
        #expect(run.status == .failed(message))
        #expect(run.pickedLane == "b")
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .succeeded)
        #expect(h.gh.calls.allSatisfy { !$0.arguments.starts(with: ["pr", "create"]) })
        // Nothing merged, nothing cleaned up.
        #expect(h.hooks.gitCalls("merge").isEmpty)
        #expect(try mainHead(h) == before)
        #expect(try localBranches(h) == branchesBefore)
        for l in launched.lanes { #expect(FileManager.default.fileExists(atPath: l.worktree.path)) }
        #expect(FileManager.default.fileExists(atPath: launched.worktree.path))
        #expect(run.keptBranches.isEmpty)

        h.hooks.stubGit("push")
        try await h.engine.retry(id, node: Self.node)
        await h.engine.waitUntilSettled(id)
        let retried = try #require(await h.engine.run(id))
        #expect(retried.status == .prOpened("b", url: Self.prURL))
        #expect(retried.nodes[Self.node]?.output == Self.prURL)
        #expect(h.hooks.gitCalls("push").count == 2)
        #expect(retried.pickedLane == "b")
    }

    @Test func aMissingOriginFailsWithGitsOwnMessage() async throws {
        let h = try Harness()
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 0, stdout: Self.prURL + "\n", stderr: ""))
        let id = try await launchToPick(h, prFlow(h))
        let run = try await pick(h, id)
        let message = try #require(failure(run))
        #expect(message.contains("origin"), "git's stderr names the missing remote: \(message)")
        #expect(h.gh.calls.allSatisfy { !$0.arguments.starts(with: ["pr", "create"]) })
    }

    @Test func aFailedPullRequestKeepsTheWorktreesAndRetrySucceeds() async throws {
        let h = try Harness()
        h.hooks.stubGit("push")
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(
            exitCode: 1, stdout: "", stderr: "To get started with GitHub CLI, please run:  gh auth login\n"))
        let id = try await launchToPick(h, prFlow(h))
        let launched = try #require(await h.engine.run(id))
        let before = try mainHead(h)

        let run = try await pick(h, id)

        let message = try #require(failure(run))
        #expect(message.contains("gh auth login"))
        #expect(run.status == .failed(message))
        #expect(try mainHead(h) == before)
        for l in launched.lanes { #expect(FileManager.default.fileExists(atPath: l.worktree.path)) }
        #expect(try localBranches(h).isSuperset(of: Set(launched.lanes.map(\.branch))))

        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 0, stdout: Self.prURL + "\n", stderr: ""))
        try await h.engine.retry(id, node: Self.node)
        await h.engine.waitUntilSettled(id)
        let retried = try #require(await h.engine.run(id))
        #expect(retried.status == .prOpened("b", url: Self.prURL))
        #expect(h.hooks.gitCalls("push").count == 2, "re-pushing is safe and happens again")
        for l in launched.lanes { #expect(!FileManager.default.fileExists(atPath: l.worktree.path)) }
    }

    @Test func anExistingPullRequestCountsAsSuccessWithTheURLFromStderr() async throws {
        let h = try Harness()
        h.hooks.stubGit("push")
        let id = try await launchToPick(h, prFlow(h))
        let launched = try #require(await h.engine.run(id))
        let b = try lane(launched, "b")
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 1, stdout: "", stderr: """
            a pull request for branch "\(b.branch)" into branch "main" already exists:
            https://github.com/acme/widgets/pull/9

            """))
        let run = try await pick(h, id)
        #expect(run.status == .prOpened("b", url: "https://github.com/acme/widgets/pull/9"))
        #expect(run.nodes[Self.node]?.output == "https://github.com/acme/widgets/pull/9")
        #expect(h.gh.calls.allSatisfy { !$0.arguments.starts(with: ["pr", "view"]) })
    }

    @Test func anExistingPullRequestWithoutAURLIsLookedUp() async throws {
        let h = try Harness()
        h.hooks.stubGit("push")
        let id = try await launchToPick(h, prFlow(h))
        let launched = try #require(await h.engine.run(id))
        let b = try lane(launched, "b")
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 1, stdout: "", stderr: "a pull request already exists"))
        h.gh.stub("gh", ["pr", "view"], result: CommandResult(exitCode: 0, stdout: "https://github.com/acme/widgets/pull/4\n", stderr: ""))
        let run = try await pick(h, id)
        #expect(run.status == .prOpened("b", url: "https://github.com/acme/widgets/pull/4"))
        let view = try #require(h.gh.calls.first { $0.arguments.starts(with: ["pr", "view"]) })
        #expect(view.arguments == ["pr", "view", b.branch, "--json", "url", "-q", ".url"])
        #expect(view.workingDirectory == launched.repo)
    }

    @Test func anExistingPullRequestThatCannotBeLookedUpFails() async throws {
        let h = try Harness()
        h.hooks.stubGit("push")
        let id = try await launchToPick(h, prFlow(h))
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 1, stdout: "", stderr: "a pull request already exists"))
        h.gh.stub("gh", ["pr", "view"], result: CommandResult(exitCode: 1, stdout: "", stderr: "no pull requests found"))
        let run = try await pick(h, id)
        #expect(failure(run) != nil)
        #expect(run.status != .prOpened("b", url: ""))
    }

    // MARK: Unpushed base

    @Test func unpublishedBaseCommitsAreWarnedAbout() async throws {
        let h = try Harness()
        stubSuccess(h)
        h.hooks.stubGit("rev-list", stdout: "3\n")
        let id = try await launchToPick(h, prFlow(h))
        let run = try await pick(h, id)
        #expect(run.nodes[Self.node]?.log.contains("main has 3 commits not on origin; they will appear in this PR.") == true)
        #expect(run.status == .prOpened("b", url: Self.prURL), "a warning never blocks")
        let args = try #require(h.hooks.gitCalls("rev-list").first)
        #expect(args == ["rev-list", "--count", "origin/main..main"])
    }

    @Test func aSyncedBaseGivesNoWarning() async throws {
        let h = try Harness()
        stubSuccess(h)
        h.hooks.stubGit("rev-list", stdout: "0\n")
        let id = try await launchToPick(h, prFlow(h))
        let run = try await pick(h, id)
        #expect(run.nodes[Self.node]?.log.contains { $0.contains("not on origin") } == false)
    }

    @Test func aMissingRemoteBaseIsWarnedAbout() async throws {
        let h = try Harness()
        stubSuccess(h)
        let id = try await launchToPick(h, prFlow(h))
        let run = try await pick(h, id)
        let log = try #require(run.nodes[Self.node]?.log)
        #expect(log.contains { $0.contains("origin/main") && $0.contains("will appear in this PR") })
        #expect(run.status == .prOpened("b", url: Self.prURL))
    }

    @Test func aFailingRevListIsIgnored() async throws {
        let h = try Harness()
        stubSuccess(h)
        h.hooks.stubGit("rev-list", exit: 128, stderr: "fatal: something else went wrong")
        let id = try await launchToPick(h, prFlow(h))
        h.hooks.stubGit("rev-parse", stdout: "abc123\n")
        let run = try await pick(h, id)
        #expect(run.nodes[Self.node]?.log.contains { $0.contains("not on origin") || $0.contains("will appear") } == false)
        #expect(run.status == .prOpened("b", url: Self.prURL))
    }

    // MARK: Odd sequences

    @Test func pickingTwiceIsRefusedAndPushesOnce() async throws {
        let h = try Harness()
        stubSuccess(h)
        let id = try await launchToPick(h, prFlow(h))
        _ = try await pick(h, id)
        await #expect(throws: RunEngineError.notPickable) { _ = try await h.engine.pick(id, lane: "a") }
        await #expect(throws: RunEngineError.notPickable) { _ = try await h.engine.pick(id, lane: "b") }
        #expect(h.hooks.gitCalls("push").count == 1)
        #expect(try #require(await h.engine.run(id)).pickedLane == "b")
    }

    @Test func pickingAnUnknownLaneChangesNothing() async throws {
        let h = try Harness()
        stubSuccess(h)
        let id = try await launchToPick(h, prFlow(h))
        await #expect(throws: RunEngineError.notPickable) { _ = try await h.engine.pick(id, lane: "z") }
        let run = try #require(await h.engine.run(id))
        #expect(run.status == .needsYou)
        #expect(run.pickedLane == nil)
        #expect(h.hooks.gitCalls("push").isEmpty)
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
        #expect(run.nodes[Self.node] == nil || run.nodes[Self.node]?.state == .waiting)
    }

    @Test func cancellingDuringTheNodeStopsItAndDiscardLeavesTheBaseAlone() async throws {
        let (hold, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let h = try Harness()
        stubSuccess(h)
        h.hooks.override({ $0.executable == "git" && CommandHooks.gitArguments($0).first == "push" }) { _ in
            for await _ in hold {}
            try Task.checkCancellation()
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let id = try await launchToPick(h, prFlow(h))
        let launched = try #require(await h.engine.run(id))
        let before = try mainHead(h)
        #expect(try await h.engine.pick(id, lane: "b") == .handedToPullRequest)
        await waitUntil("the push to start") { !h.hooks.gitCalls("push").isEmpty }

        await h.engine.cancel(id)
        release.finish()
        await h.engine.waitUntilSettled(id)

        var run = try #require(await h.engine.run(id))
        #expect(run.status == .cancelled)
        #expect(run.nodes[Self.node]?.state == .cancelled)
        #expect(h.gh.calls.allSatisfy { !$0.arguments.starts(with: ["pr", "create"]) })
        for l in launched.lanes { #expect(FileManager.default.fileExists(atPath: l.worktree.path)) }
        // A cancelled node is not a failed one: it cannot be retried.
        await #expect(throws: RunEngineError.notRetryable(Self.node)) { try await h.engine.retry(id, node: Self.node) }

        try await h.engine.discard(id)
        run = try #require(await h.engine.run(id))
        #expect(run.status == .discarded)
        for l in launched.lanes { #expect(!FileManager.default.fileExists(atPath: l.worktree.path)) }
        #expect(try mainHead(h) == before)
        #expect(try localBranches(h) == ["main"])
    }

    @Test func discardingAfterAFailureRemovesTheRunAndLeavesTheBaseAlone() async throws {
        let h = try Harness()
        h.hooks.stubGit("push", exit: 1, stderr: "fatal: no network")
        let id = try await launchToPick(h, prFlow(h))
        let launched = try #require(await h.engine.run(id))
        let before = try mainHead(h)
        let run = try await pick(h, id)
        #expect(failure(run) != nil)

        try await h.engine.discard(id)

        let discarded = try #require(await h.engine.run(id))
        #expect(discarded.status == .discarded)
        for l in launched.lanes { #expect(!FileManager.default.fileExists(atPath: l.worktree.path)) }
        #expect(try mainHead(h) == before)
        #expect(try localBranches(h) == ["main"])
        #expect(h.hooks.gitCalls("merge").isEmpty)
    }

    @Test func aRunStoppedAtTheNodeResumesWithItsPickedLane() async throws {
        let (hold, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        let h = try Harness()
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 0, stdout: Self.prURL + "\n", stderr: ""))
        h.hooks.override({ $0.executable == "git" && CommandHooks.gitArguments($0).first == "push" }) { _ in
            for await _ in hold {}
            try Task.checkCancellation()
            return CommandResult(exitCode: 0, stdout: "", stderr: "")
        }
        let id = try await launchToPick(h, prFlow(h))
        #expect(try await h.engine.pick(id, lane: "b") == .handedToPullRequest)
        await waitUntil("the push to start") { !h.hooks.gitCalls("push").isEmpty }

        // The app quits (or crashes) while the node runs.
        await h.engine.suspend(id)
        release.finish()
        await h.engine.waitUntilSettled(id)

        let runner = RoutingRunner(gh: h.gh, hooks: h.hooks)
        let engine = RunEngine(store: h.store, runner: runner, agent: h.agent, issues: GitHubIssues(runner: runner))
        let restored = try #require(try await engine.restore().first { $0.id == id })
        #expect(restored.pickedLane == "b", "reloading must not lose the pick")
        #expect(restored.nodes[Self.node]?.state == .interrupted)
        #expect(restored.status == .needsYou)

        h.hooks.stubGit("push")
        try await engine.resumeInterrupted(id)
        await engine.waitUntilSettled(id)
        let run = try #require(await engine.run(id))
        #expect(run.status == .prOpened("b", url: Self.prURL))
        #expect(run.pickedLane == "b")
    }

    @Test func aCrashBetweenTheStatusAndTheCleanupIsFinishedOnRestoreKeepingTheBranch() async throws {
        let h = try Harness()
        stubSuccess(h)
        let id = try await launchToPick(h, prFlow(h))
        let run = try await pick(h, id)
        let branch = try #require(run.lanes.first { $0.id == "b" }).branch
        // Pretend the process died before the worktrees were removed.
        let leftover = h.store.worktreesDirectory.appendingPathComponent(id.rawValue).appendingPathComponent("run")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)

        let runner = RoutingRunner(gh: h.gh, hooks: h.hooks)
        let engine = RunEngine(store: h.store, runner: runner, agent: h.agent, issues: GitHubIssues(runner: runner))
        let restored = try await engine.restore()
        await engine.waitForRestoreCleanups()

        #expect(restored.first { $0.id == id }?.status == .prOpened("b", url: Self.prURL))
        #expect(!FileManager.default.fileExists(atPath: h.store.worktreesDirectory.appendingPathComponent(id.rawValue).path))
        #expect(try localBranches(h).contains(branch))
    }

    @Test func retryingALaneAfterThePickForgetsThePick() async throws {
        // A lane that fails after the pick node succeeded (only possible if a lane node is retried) resets the pick.
        let h = try Harness()
        h.hooks.stubGit("push", exit: 1, stderr: "fatal: no network")
        let id = try await launchToPick(h, prFlow(h))
        _ = try await pick(h, id)
        await h.engine.setDirect(id) { $0.nodes[NodeKey(node: "implement", lane: "c")]?.state = .failed("late") }
        try await h.engine.retry(id, node: NodeKey(node: "implement", lane: "c"))
        await h.engine.waitUntilSettled(id)
        let run = try #require(await h.engine.run(id))
        #expect(run.status == .needsYou)
        #expect(run.pickedLane == nil)
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
    }
}

/// Helpers for reading recorded `git` commands.
enum DispatchedPush {
    static func isPush(_ c: Command) -> Bool { CommandHooks.gitArguments(c).first == "push" }
}
