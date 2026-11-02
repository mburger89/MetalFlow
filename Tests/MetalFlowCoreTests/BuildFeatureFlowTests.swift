import CryptoKit
import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct BuildFeatureFlowTests {
    typealias Harness = RunEngineTests.Harness
    private let flow = BuiltinFlows.buildFeature

    // MARK: Shape

    @Test func validatesWithTwoLanesAndLaneScopedGateAndReview() throws {
        #expect(flow.name == "Build a feature")
        let plan = try flow.validate()
        #expect(plan.fanOut == "implement")
        #expect(plan.laneScoped == ["implement", "gate", "review"])
        guard case .prompt(let implement)? = flow.node("implement")?.kind else { Issue.record("no implement"); return }
        #expect(implement.candidates == ["sonnet", "opus"])
        #expect(implement.model == "sonnet")
        #expect(flow.hasOpenPR)
    }

    @Test func everyPlaceholderIsWired() throws {
        for node in flow.nodes {
            let wired = Set(flow.inputs(of: node.id).map(\.input))
            for name in flow.inputNames(of: node.id) {
                #expect(wired.contains(name), "\(node.id) has no wire for {\(name)}")
            }
        }
        #expect(flow.wires.contains(Wire(from: "implement", to: "gate", input: "code")))
        #expect(flow.wires.contains(Wire(from: "gate", to: "review", input: "code")))
        #expect(flow.wires.contains(Wire(from: "review", to: "judge", input: "results")))
        #expect(flow.wires.contains(Wire(from: "judge", to: "pick", input: "recommendation")))
        #expect(flow.wires.contains(Wire(from: "pick", to: "openpr", input: "approval")))
        #expect(Set(flow.inputNames(of: "plan")) == ["feature", "repo"])
        #expect(Set(flow.inputNames(of: "implement")) == ["feature", "plan"])
        #expect(Set(flow.inputNames(of: "review")) == ["feature", "plan"])
        #expect(Set(flow.inputNames(of: "judge")) == ["feature"])
    }

    @Test func gateReviewAndOpenPRSettings() {
        guard case .gate(let gate)? = flow.node("gate")?.kind else { Issue.record("no gate"); return }
        #expect(gate.command == "swift test")
        #expect(gate.fixAttempts == 2)
        guard case .review(let review)? = flow.node("review")?.kind else { Issue.record("no review"); return }
        #expect(review.fixAttempts == 1)
        var expected = ReviewConfig.defaultAgent
        expected.prompt = "Review this change against the feature request and the plan. Look for anything the plan promised that is missing, bugs, and missing tests. Do not edit files. List only the problems worth fixing, each with its file and line.\n\nFeature:\n{feature}\n\nPlan:\n{plan}\n\n{diff}"
        #expect(review.agent == expected)
        #expect(flow.node("openpr")?.kind == .openPR(OpenPRConfig(draft: true)))
        #expect(flow.node("pick")?.kind == .pick)
        guard case .flowInput(let input)? = flow.node("feature")?.kind else { Issue.record("no input"); return }
        #expect(input == FlowInputConfig(name: "feature", source: .text))
        #expect(flow.node("repo")?.kind == .repo(RepoConfig(mode: .exposed(default: nil))))
    }

    @Test func promptsAreVerbatim() {
        guard case .prompt(let plan)? = flow.node("plan")?.kind,
              case .prompt(let implement)? = flow.node("implement")?.kind,
              case .judge(let judge)? = flow.node("judge")?.kind else { Issue.record("missing nodes"); return }
        #expect(plan.model == "opus")
        #expect(plan.prompt == "Read this feature request and the code in this repository ({repo}), then write a short plan to build it. Say what it will do, what it will not do, the numbered steps, and which tests will prove it works. Do not edit files.\n\nFeature:\n{feature}")
        #expect(implement.prompt == "Build this feature by following the plan. Keep existing public APIs working, add tests for what the plan says it will do, and stop when swift test passes.\n\nFeature:\n{feature}\n\nPlan:\n{plan}")
        #expect(judge.model == "opus")
        #expect(judge.prompt == "You are judging candidate builds of this feature. Prefer candidates whose tests pass and whose review approved, then the one that does the most of what the feature asks with the least code. Explain briefly, then end with a final line `RECOMMEND: <lane>`.\n\nFeature:\n{feature}\n\nCandidates:\n{candidates}")
        let fix = BuiltinFlows.fixGitHubIssue
        guard case .prompt(let fixPlan)? = fix.node("plan")?.kind, case .prompt(let fixImplement)? = fix.node("implement")?.kind
        else { Issue.record("missing fix nodes"); return }
        #expect(plan.allowedTools == fixPlan.allowedTools)
        #expect(implement.allowedTools == fixImplement.allowedTools)
    }

    @Test func nothingOverlaps() {
        let width = 200.0
        for (i, a) in flow.nodes.enumerated() {
            for b in flow.nodes[(i + 1)...] {
                let apartX = abs(a.position.x - b.position.x) >= width
                let apartY = abs(a.position.y - b.position.y) >= 140
                #expect(apartX || apartY, "\(a.id) overlaps \(b.id)")
            }
        }
        // Left to right: no wire goes back (judge to pick is a column, as in Fix GitHub issue).
        for wire in flow.wires {
            #expect(flow.node(wire.from)!.position.x <= flow.node(wire.to)!.position.x, "\(wire.from) -> \(wire.to)")
        }
    }

    @Test func launchFieldsAreTheFeatureAndTheRepo() throws {
        let fields = try flow.launchFields(location: .builtin)
        #expect(fields == [LaunchField(name: "feature", kind: .text), LaunchField(name: "repo", kind: .repo)])
    }

    // MARK: Built-ins

    @Test func allListsBothWithFixGitHubIssueFirst() {
        #expect(BuiltinFlows.all.map(\.name) == ["Fix GitHub issue", "Build a feature"])
        #expect(BuiltinFlows.all[0] == BuiltinFlows.fixGitHubIssue && BuiltinFlows.all[1] == BuiltinFlows.buildFeature)
        #expect(BuiltinFlows.named("Build a feature") == BuiltinFlows.buildFeature)
        #expect(BuiltinFlows.named("Fix GitHub issue") == BuiltinFlows.fixGitHubIssue)
        #expect(BuiltinFlows.named("nope") == nil)
        for flow in BuiltinFlows.all { #expect(throws: Never.self) { try flow.launchFields(location: .builtin) } }
    }

    @Test func fixGitHubIssueIsUnchanged() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(BuiltinFlows.fixGitHubIssue)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == "650fecffae969a68fce37b89e41cdada8f8e611efdb4b3beed5a3b4031b8ed53")
    }

    // MARK: A run with no GitHub issue

    private func finished(_ text: String) -> [AgentEvent] {
        [.started(sessionID: "s"), .text(text),
         .finished(AgentResult(sessionID: "s", text: text, isError: false, deniedTools: [], costUSD: 0.5, turns: 1))]
    }

    private func harness() throws -> (Harness, Flow) {
        let h = try Harness()
        var flow = BuiltinFlows.buildFeature
        let i = flow.nodes.firstIndex { $0.id == "gate" }!
        flow.nodes[i].kind = .gate(ShellConfig(command: "test -f ok.txt"))
        h.agent.script({ $0.prompt.contains("write a short plan to build it") }, events: finished("PLAN: do it"))
        h.agent.script({ $0.prompt.contains("Build this feature by following the plan") }, effect: { r in
            try "ok".write(to: r.workingDirectory.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
        }, events: finished("built"))
        h.agent.script({ $0.prompt.contains("Review this change against the feature request") },
                       events: finished("Fine.\nVERDICT: approve"))
        h.hooks.stubGit("push")
        h.gh.stub("gh", ["pr", "create"], result: CommandResult(exitCode: 0, stdout: "https://github.com/acme/w/pull/3\n", stderr: ""))
        return (h, flow)
    }

    @Test func launchesWithFeatureTextAndNoIssue() async throws {
        let (h, flow) = try harness()
        let text = "Add a dark mode toggle to the settings screen so people can pick a theme"
        let id = try await h.engine.launch(flow: flow, location: .builtin, values: ["feature": text, "repo": h.repo.url.path])
        let run = await h.settled(id)
        #expect(run.status == .needsYou)
        #expect(run.title == String(text.prefix(60)))
        #expect(run.branch == "flow/" + BranchNaming.slug(String(text.prefix(60))))
        #expect(run.branch == "flow/add-a-dark-mode-toggle-to-the")
        #expect(run.inputs["feature"] == text)
        #expect(run.lanes.map(\.id) == ["a", "b"])
        #expect(run.lanes.map(\.model) == ["sonnet", "opus"])
        #expect(run.lanes.map(\.gatePassed) == [true, true])
        #expect(run.lanes.map(\.reviewPassed) == [true, true])
        #expect(h.gh.calls.allSatisfy { !$0.arguments.starts(with: ["issue", "view"]) })
        let planPrompt = try #require(h.agent.requests.first { $0.prompt.contains("write a short plan") }).prompt
        #expect(planPrompt.hasSuffix("Feature:\n" + text) && !planPrompt.contains("{"))
        let implementPrompt = try #require(h.agent.requests.first { $0.prompt.contains("Build this feature") }).prompt
        #expect(implementPrompt.contains("Feature:\n\(text)\n\nPlan:\nPLAN: do it"))
    }

    @Test func thePullRequestBodyHasNoClosesLine() async throws {
        let (h, flow) = try harness()
        let id = try await h.engine.launch(flow: flow, location: .builtin,
                                           values: ["feature": "#12 Speed up launch", "repo": h.repo.url.path])
        _ = await h.settled(id)
        await h.engine.waitForPass(id)
        #expect(try await h.engine.pick(id, lane: "b") == .handedToPullRequest)
        await h.engine.waitUntilSettled(id)
        let run = try #require(await h.engine.run(id))
        guard case .prOpened("b", _) = run.status else { Issue.record("no PR: \(run.status)"); return }
        let args = try #require(h.gh.calls.first { $0.arguments.starts(with: ["pr", "create"]) }).arguments
        #expect(args[args.firstIndex(of: "--title")! + 1] == "Speed up launch")
        #expect(args[args.firstIndex(of: "--body")! + 1] == "Candidate b (opus), tests passed, review approved, chosen in MetalFlow.")
        #expect(args.contains("--draft"))
        #expect(h.gh.calls.allSatisfy { !$0.arguments.contains { $0.contains("Closes") } })
    }
}
