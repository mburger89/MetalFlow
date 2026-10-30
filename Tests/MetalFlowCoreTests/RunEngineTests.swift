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

        init(planHold: AsyncStream<Void>? = nil) throws {
            repo = try TempRepo()
            root = repo.worktreePath("store")
            store = RunStore(root: root)
            gh.stub("gh", ["issue", "view"], result: CommandResult(exitCode: 0, stdout: """
                {"number":7,"title":"Crash on launch","body":"Boom","url":"https://x/7","labels":[]}
                """, stderr: ""))
            let runner = RoutingRunner(gh: gh)
            engine = RunEngine(store: store, runner: runner, agent: agent, issues: GitHubIssues(runner: runner))

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
