import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct RunEngineTests {
    struct Harness {
        let repo: TempRepo
        let root: URL
        let agent = FakeAgent()
        let gh = FakeCommandRunner()
        let engine: RunEngine
        let store: RunStore

        init(planHold: AsyncStream<Void>? = nil, maxSessions: Int = 4) throws {
            repo = try TempRepo()
            root = repo.worktreePath("store")
            store = RunStore(root: root)
            gh.stub("gh", ["issue", "view"], result: CommandResult(exitCode: 0, stdout: """
                {"number":7,"title":"Crash on launch","body":"Boom","url":"https://x/7","labels":[]}
                """, stderr: ""))
            let runner = RoutingRunner(gh: gh)
            engine = RunEngine(store: store, runner: runner, agent: agent, issues: GitHubIssues(runner: runner),
                                maxSessions: maxSessions)

            func finished(_ text: String, error: Bool = false) -> [AgentEvent] {
                [.started(sessionID: "s"), .text(text),
                 .finished(AgentResult(sessionID: "s", text: text, isError: error, deniedTools: [], costUSD: 0.5, turns: 1))]
            }
            agent.script({ $0.prompt.contains("short numbered plan") }, hold: planHold, events: finished("PLAN: change the thing"))
            agent.script({ $0.prompt.contains("Fix this GitHub issue") }, effect: { r in
                let lane = r.workingDirectory.lastPathComponent
                if lane == "a" || lane == "b" {
                    try "ok".write(to: r.workingDirectory.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
                }
            }, events: finished("done"))
            agent.script({ $0.prompt.contains("judging candidate") }, events: finished("Fine.\nRECOMMEND: b"))
        }

        func flow() -> Flow {
            var flow = BuiltinFlows.fixGitHubIssue
            let i = flow.nodes.firstIndex { $0.id == "gate" }!
            flow.nodes[i].kind = .gate(ShellConfig(command: "test -f ok.txt"))
            return flow
        }

        func settled(_ id: RunID) async -> Run {
            for await run in engine.updates where run.id == id && run.status != .running { return run }
            fatalError("updates ended")
        }
    }

    @Test func fixIssueRunsToPickWinner() async throws {
        let h = try Harness()
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        let run = await h.settled(id)
        #expect(run.status == .needsYou)
        #expect(run.title == "#7 Crash on launch")
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
        #expect(run.lanes.map(\.gatePassed) == [true, true, false])
        #expect(run.recommendation == "b")
        let branches = try h.repo.git(["branch", "--list", "flow/*"])
        for lane in ["a", "b", "c"] { #expect(branches.contains("\(run.branch)--\(lane)")) }
        #expect(try h.repo.gitStatus(["status", "--porcelain"]).out.isEmpty)
        #expect(run.lanes[0].added == 1)
    }

    @Test func leftoverLaneBranchIsNotAdoptedByNewRun() async throws {
        let h = try Harness()
        try h.repo.git(["checkout", "-b", "flow/7-crash-on-launch--a"])
        try h.repo.write("stale.txt", "stale\n")
        try h.repo.commit("unrelated stale commit")
        try h.repo.git(["checkout", "main"])
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        let run = await h.settled(id)
        #expect(run.branch == "flow/7-crash-on-launch-2")
        let laneA = try #require(run.lanes.first { $0.id == "a" })
        #expect(laneA.branch == "\(run.branch)--a")
        let log = try h.repo.git(["log", "--format=%s", laneA.branch])
        #expect(!log.contains("unrelated stale commit"))
    }

    @Test func placeholdersReachPrompts() async throws {
        let h = try Harness()
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        _ = await h.settled(id)
        let implement = h.agent.requests.filter { $0.prompt.contains("Fix this GitHub issue") }
        #expect(implement.count == 3)
        for r in implement {
            #expect(r.prompt.contains("PLAN: change the thing"))
            #expect(r.prompt.contains("Crash on launch"))
        }
        #expect(Set(implement.map(\.model)) == ["sonnet", "opus", "haiku"])
    }

    @Test func questionPausesOnlyThatLane() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.contains("Fix this GitHub issue") && $0.workingDirectory.lastPathComponent == "b" },
                       events: [.started(sessionID: "sb"), .finished(AgentResult(
                        sessionID: "sb", text: "hmm\nQUESTION: Keep the API?", isError: false, deniedTools: [], costUSD: 0, turns: 1))])
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        let run = await h.settled(id)
        #expect(run.status == .needsYou)
        #expect(run.nodes[NodeKey(node: "implement", lane: "b")]?.state == .needsYou(.question("Keep the API?")))
        #expect(run.nodes[NodeKey(node: "implement", lane: "b")]?.sessionID == "sb")
        #expect(run.nodes[NodeKey(node: "gate", lane: "a")]?.state == .succeeded)
        #expect(run.nodes[NodeKey(node: "gate", lane: "c")]?.state == .succeeded)
        #expect(run.nodes[NodeKey(node: "gate", lane: "b")] == nil)
        #expect(run.nodes[NodeKey(node: "judge")] == nil)
    }

    @Test func agentErrorFailsLaneNotRun() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.contains("Fix this GitHub issue") && $0.workingDirectory.lastPathComponent == "c" },
                       events: [.finished(AgentResult(
                        sessionID: "sc", text: "boom", isError: true, deniedTools: [], costUSD: 0, turns: 1))])
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        let run = await h.settled(id)
        #expect(run.nodes[NodeKey(node: "implement", lane: "c")]?.state == .failed("boom"))
        #expect(run.nodes[NodeKey(node: "judge")]?.state == .succeeded)
        #expect(run.status == .needsYou)
        let judge = h.agent.requests.first { $0.prompt.contains("judging candidate") }
        #expect(judge?.prompt.contains("## c (haiku) — failed: boom") == true)
    }

    @Test func cancelStopsRun() async throws {
        let (hold, holdCont) = AsyncStream<Void>.makeStream()
        defer { holdCont.finish() }
        let h = try Harness(planHold: hold)
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        for await run in h.engine.updates where run.id == id && run.nodes[NodeKey(node: "plan")]?.state == .running { break }
        await h.engine.cancel(id)
        let run = await h.settled(id)
        #expect(run.status == .cancelled)
        #expect(run.nodes[NodeKey(node: "plan")]?.state == .cancelled)
        await h.engine.waitForPass(id)
        #expect(await h.engine.tasks[id] == nil)
        await waitUntil("the cancelled session") { h.agent.cancelledCount > 0 }
        #expect(h.agent.cancelledCount == 1)
        #expect(await h.engine.run(id)?.nodes.values.contains { $0.state == .running } == false)
    }

    @Test func cancelOnSettledRunIsNoOp() async throws {
        let h = try Harness()
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        let run = await h.settled(id)
        #expect(run.status == .needsYou)
        await h.engine.cancel(id)
        let after = await h.engine.run(id)
        #expect(after?.status == .needsYou)
        #expect(after?.nodes[NodeKey(node: "pick")]?.state == run.nodes[NodeKey(node: "pick")]?.state)
    }

    @Test func builtinImplementPromptDoesNotAskForCommit() {
        let implement = BuiltinFlows.fixGitHubIssue.nodes.first { $0.id == "implement" }
        guard case .prompt(let c)? = implement?.kind else { Issue.record("no implement node"); return }
        #expect(c.prompt.contains("stop when swift test passes"))
        #expect(!c.prompt.contains("commit"))
    }

    @Test func pickLessFlowWithOneFailedLaneCompletes() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.contains("Fix this GitHub issue") && $0.workingDirectory.lastPathComponent == "c" },
                       events: [.finished(AgentResult(sessionID: "c", text: "boom", isError: true, deniedTools: [], costUSD: 0, turns: 1))])
        let flow = Flow(name: "nopick", nodes: [
            Node(id: "implement", title: "Implement", kind: .prompt(PromptConfig(
                model: "sonnet", prompt: "Fix this GitHub issue", candidates: ["a", "b", "c"],
                allowedTools: [], maxTurns: nil)), position: Point(x: 0, y: 0)),
            Node(id: "gate", title: "Gate", kind: .gate(ShellConfig(command: "test -f ok.txt")), position: Point(x: 1, y: 0)),
        ], wires: [Wire(from: "implement", to: "gate", input: "code")])
        let id = try await h.engine.launch(flow: flow, repo: h.repo.url, input: "")
        let run = await h.settled(id)
        #expect(run.status == .completed)
        #expect(run.nodes[NodeKey(node: "implement", lane: "c")]?.state == .failed("boom"))
    }

    @Test func tooManyCandidatesRejectedAtLaunch() async throws {
        let h = try Harness()
        let flow = Flow(name: "many", nodes: [
            Node(id: "implement", title: "Implement", kind: .prompt(PromptConfig(
                model: "sonnet", prompt: "x", candidates: (0..<27).map { "m\($0)" },
                allowedTools: [], maxTurns: nil)), position: Point(x: 0, y: 0)),
        ], wires: [])
        await #expect(throws: RunEngineError.tooManyCandidates(27)) {
            _ = try await h.engine.launch(flow: flow, repo: h.repo.url, input: "")
        }
        #expect(try h.repo.git(["worktree", "list"]).split(separator: "\n").count == 1)
    }

    @Test func flowWithoutPickCompletes() async throws {
        let h = try Harness()
        let flow = Flow(name: "simple", nodes: [
            Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: .thisRepo)), position: Point(x: 0, y: 0)),
            Node(id: "plan", title: "Plan", kind: .prompt(PromptConfig(
                model: "opus", prompt: "Write a short numbered plan for {repo}", candidates: [],
                allowedTools: [], maxTurns: nil)), position: Point(x: 1, y: 0)),
            Node(id: "show", title: "Show", kind: .shell(ShellConfig(command: "echo {plan}")), position: Point(x: 2, y: 0)),
        ], wires: [Wire(from: "repo", to: "plan", input: "repo"), Wire(from: "plan", to: "show", input: "plan")])
        let id = try await h.engine.launch(flow: flow, repo: h.repo.url, input: "")
        let run = await h.settled(id)
        #expect(run.status == .completed)
        #expect(run.title == "simple")
        #expect(run.nodes[NodeKey(node: "show")]?.state == .succeeded)
    }

    @Test func nonLaneFeederRunsBeforeLanes() async throws {
        let h = try Harness()
        let flow = Flow(name: "feeder", nodes: [
            Node(id: "implement", title: "Implement", kind: .prompt(PromptConfig(
                model: "sonnet", prompt: "Fix this GitHub issue", candidates: ["sonnet", "opus"],
                allowedTools: [], maxTurns: nil)), position: Point(x: 0, y: 0)),
            Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: .thisRepo)), position: Point(x: 0, y: 1)),
            Node(id: "setup", title: "Setup", kind: .shell(ShellConfig(command: "echo SETUPOUT")), position: Point(x: 1, y: 1)),
            Node(id: "gate", title: "Gate", kind: .gate(ShellConfig(command: "echo {setup}; test -f ok.txt")), position: Point(x: 2, y: 0)),
        ], wires: [
            Wire(from: "repo", to: "setup", input: "repo"),
            Wire(from: "implement", to: "gate", input: "code"),
            Wire(from: "setup", to: "gate", input: "setup"),
        ])
        let id = try await h.engine.launch(flow: flow, repo: h.repo.url, input: "")
        let run = await h.settled(id)
        #expect(run.status == .completed)
        let out = run.nodes[NodeKey(node: "gate", lane: "a")]?.output ?? ""
        #expect(out.contains("SETUPOUT"))
        #expect(out.contains("exit 0"))
    }

    @Test func engineRoutesAgentCallsThroughLimiter() async throws {
        let h = try Harness(maxSessions: 1)
        var releases: [AsyncStream<Void>.Continuation] = []
        for lane in ["a", "b", "c"] {
            let (hold, cont) = AsyncStream<Void>.makeStream()
            releases.append(cont)
            h.agent.script({ $0.prompt.contains("Fix this GitHub issue") && $0.workingDirectory.lastPathComponent == lane },
                           hold: hold, events: [.finished(AgentResult(
                            sessionID: lane, text: "done", isError: false, deniedTools: [], costUSD: 0, turns: 1))])
        }
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        func started() -> Int { h.agent.requests.filter { $0.prompt.contains("Fix this GitHub issue") }.count }
        await waitUntil("the first lane to start") { started() >= 1 }
        for _ in 0..<200 { await Task.yield() }
        #expect(started() == 1)
        releases.forEach { $0.finish() }
        let run = await h.settled(id)
        #expect(started() == 3)
        #expect(run.status == .needsYou)
    }

    @Test func recommendationParsing() {
        func lane(_ id: String) -> Lane { Lane(id: id, model: "m", branch: "b", worktree: URL(fileURLWithPath: "/tmp")) }
        let lanes = [lane("a"), lane("b")]
        #expect(RunEngine.recommendation(in: "no marker here", lanes: lanes) == nil)
        #expect(RunEngine.recommendation(in: "RECOMMEND: z", lanes: lanes) == nil)
        #expect(RunEngine.recommendation(in: "RECOMMEND: a\nthoughts\nRECOMMEND: b\n", lanes: lanes) == "b")
        #expect(RunEngine.recommendation(in: "`RECOMMEND: a`", lanes: lanes) == "a")
    }

    @Test func missingExecutableErrorIsReadable() async throws {
        let h = try Harness()
        h.agent.script({ $0.prompt.contains("short numbered plan") }, throwing: CommandError.executableNotFound("claude"))
        let id = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        let run = await h.settled(id)
        guard case .failed(let message)? = run.nodes[NodeKey(node: "plan")]?.state else {
            Issue.record("plan did not fail"); return
        }
        #expect(message.contains("claude"))
        #expect(CommandError.failed(Command(executable: "git", arguments: ["x"]), exitCode: 2, stderr: "boom\n")
            .localizedDescription.contains("boom"))
    }

    @Test func ghErrorThrowsFromLaunchWithoutWorktree() async throws {
        let h = try Harness()
        h.gh.stub("gh", ["issue", "view"], result: CommandResult(exitCode: 1, stdout: "", stderr: "no such issue"))
        await #expect(throws: CommandError.self) {
            _ = try await h.engine.launch(flow: h.flow(), repo: h.repo.url, input: "7")
        }
        #expect(try h.repo.git(["worktree", "list"]).split(separator: "\n").count == 1)
    }
}
