import Foundation
import Testing
@testable import MetalFlowCore

/// Launching with named values: exposed and fixed inputs, the repo rules, and runs saved before inputs existed.
@Suite struct RunEngineLaunchValuesTests {
    typealias Harness = RunEngineTests.Harness

    private func finished(_ text: String) -> [AgentEvent] {
        [.started(sessionID: "s"), .text(text),
         .finished(AgentResult(sessionID: "s", text: text, isError: false, deniedTools: [], costUSD: 0, turns: 1))]
    }

    private func repoNode(_ mode: RepoMode, at x: Double = 0) -> Node {
        Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: mode)), position: Point(x: x, y: 0))
    }

    /// repo -> ask (a prompt using `{env}`), with `env` bound as given.
    private func promptFlow(_ binding: InputBinding?, repo: RepoMode = .exposed(default: nil)) -> Flow {
        Flow(name: "ask", nodes: [
            repoNode(repo),
            Node(id: "ask", title: "Ask", kind: .prompt(PromptConfig(
                model: "sonnet", prompt: "ENVMARK deploy to {env} in {repo}", candidates: [], allowedTools: [], maxTurns: nil)),
                 position: Point(x: 1, y: 0), inputs: binding.map { ["env": $0] } ?? [:]),
        ], wires: [Wire(from: "repo", to: "ask", input: "repo")])
    }

    private func settledWithPrompt(_ h: Harness, _ flow: Flow, location: FlowLocation = .builtin,
                                   values: [String: String]) async throws -> (Run, String?) {
        h.agent.script({ $0.prompt.contains("ENVMARK") }, events: finished("ok"))
        let id = try await h.engine.launch(flow: flow, location: location, values: values)
        let run = await h.settled(id)
        return (run, h.agent.requests.last { $0.prompt.contains("ENVMARK") }?.prompt)
    }

    @Test func launchResolvesExposedRepo() async throws {
        let h = try Harness()
        let id = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
        let run = await h.settled(id)
        #expect(run.repo == h.repo.url)
        #expect(run.inputs == ["issue": "7", "repo": h.repo.url.path])
    }

    @Test func launchRecordsFlowFile() async throws {
        let h = try Harness()
        let values = ["issue": "7", "repo": h.repo.url.path]
        let lib = URL(fileURLWithPath: "/tmp/lib/a.flow")
        let repoFile = URL(fileURLWithPath: "/tmp/r/.flows/b.flow")
        let cases: [(FlowLocation, URL?)] = [
            (.library(file: lib), lib),
            (.repo(root: URL(fileURLWithPath: "/tmp/r", isDirectory: true), file: repoFile), repoFile),
            (.builtin, nil), (.unsaved, nil),
        ]
        for (location, expected) in cases {
            let id = try await h.engine.launch(flow: h.flow(), location: location, values: values)
            let run = await h.settled(id)
            await h.engine.waitForPass(id)
            #expect(run.flowFile == expected)
        }
    }

    @Test func launchMissingRequiredThrows() async throws {
        let h = try Harness()
        await #expect(throws: RunEngineError.missingInput("issue")) {
            _ = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["repo": h.repo.url.path])
        }
        await #expect(throws: RunEngineError.missingInput("repo")) {
            _ = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7"])
        }
        #expect(try h.repo.git(["worktree", "list"]).split(separator: "\n").count == 1)
    }

    @Test func launchUsesExposedDefault() async throws {
        let h = try Harness()
        let flow = promptFlow(.exposed(default: "dev"))
        let (run, prompt) = try await settledWithPrompt(h, flow, values: ["repo": h.repo.url.path])
        #expect(run.status == .completed)
        #expect(prompt == "ENVMARK deploy to dev in \(h.repo.url.path)")
        #expect(run.inputs["env"] == "dev")
        let (_, typed) = try await settledWithPrompt(h, flow, values: ["repo": h.repo.url.path, "env": "prod"])
        #expect(typed?.contains("deploy to prod") == true)
    }

    @Test func fixedInputFillsPrompt() async throws {
        let h = try Harness()
        let (run, prompt) = try await settledWithPrompt(h, promptFlow(.fixed("hello")), values: ["repo": h.repo.url.path])
        #expect(prompt == "ENVMARK deploy to hello in \(h.repo.url.path)")
        #expect(run.inputs["env"] == nil)
    }

    @Test func exposedValueIsShellQuoted() async throws {
        let h = try Harness()
        let flow = Flow(name: "quote", nodes: [
            repoNode(.exposed(default: nil)),
            Node(id: "show", title: "Show", kind: .shell(ShellConfig(command: "printf '[%s]' {name}")),
                 position: Point(x: 1, y: 0), inputs: ["name": .exposed(default: nil)]),
        ], wires: [Wire(from: "repo", to: "show", input: "repo")])
        let evil = "a'; touch pwned; echo '"
        let id = try await h.engine.launch(flow: flow, location: .builtin, values: ["name": evil, "repo": h.repo.url.path])
        let run = await h.settled(id)
        #expect(run.status == .completed)
        #expect(run.nodes[NodeKey(node: "show")]?.output?.contains("[\(evil)]") == true)
        #expect(!FileManager.default.fileExists(atPath: run.worktree.appendingPathComponent("pwned").path))
    }

    @Test func thisRepoUsesLocationRoot() async throws {
        let h = try Harness()
        let other = try TempRepo()
        let flow = promptFlow(.fixed("x"), repo: .thisRepo)
        let location = FlowLocation.repo(root: h.repo.url, file: h.repo.url.appendingPathComponent(".flows/ask.flow"))
        let (run, _) = try await settledWithPrompt(h, flow, location: location, values: [:])
        #expect(run.repo == h.repo.url)
        let (same, _) = try await settledWithPrompt(h, flow, location: location, values: ["repo": h.repo.url.path])
        #expect(same.repo == h.repo.url)
        await #expect(throws: RunEngineError.repoMismatch(expected: h.repo.url)) {
            _ = try await h.engine.launch(flow: flow, location: location, values: ["repo": other.url.path])
        }
    }

    @Test func repoMatchResolvesSymlinksAndDots() async throws {
        let h = try Harness()
        let flow = promptFlow(.fixed("x"), repo: .thisRepo)
        let link = h.root.deletingLastPathComponent().appendingPathComponent("link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: link) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: h.repo.url)
        let viaLink = FlowLocation.repo(root: link, file: link.appendingPathComponent(".flows/ask.flow"))
        let (a, _) = try await settledWithPrompt(h, flow, location: viaLink, values: ["repo": h.repo.url.path])
        #expect(a.status == .completed)
        let location = FlowLocation.repo(root: h.repo.url, file: h.repo.url.appendingPathComponent(".flows/ask.flow"))
        let (b, _) = try await settledWithPrompt(h, flow, location: location, values: ["repo": link.path + "/"])
        #expect(b.status == .completed)
        let dotted = h.repo.url.path + "/sub/.."
        let (c, _) = try await settledWithPrompt(h, flow, location: location, values: ["repo": dotted])
        #expect(c.status == .completed)

        // The classic case: /tmp is a symlink to /private/tmp.
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        if tmp.hasPrefix("/private/") {
            let unresolved = String(tmp.dropFirst("/private".count)) + h.repo.url.path.dropFirst(tmp.count)
            if FileManager.default.fileExists(atPath: unresolved) {
                let (d, _) = try await settledWithPrompt(h, flow, location: location, values: ["repo": unresolved])
                #expect(d.status == .completed)
            }
        }
    }

    @Test func fixedRepoRejectsADifferentRepo() async throws {
        let h = try Harness()
        let other = try TempRepo()
        let flow = promptFlow(.fixed("x"), repo: .fixed(path: h.repo.url.path))
        await #expect(throws: RunEngineError.repoMismatch(expected: h.repo.url)) {
            _ = try await h.engine.launch(flow: flow, location: .unsaved, values: ["repo": other.url.path])
        }
        let (run, _) = try await settledWithPrompt(h, flow, location: .unsaved, values: [:])
        #expect(run.repo == h.repo.url)
    }

    @Test func launchErrorsAreWrapped() async throws {
        let h = try Harness()
        let flow = promptFlow(.fixed("x"), repo: .thisRepo)
        await #expect(throws: RunEngineError.launch(.thisRepoOutsideRepo)) {
            _ = try await h.engine.launch(flow: flow, location: .unsaved, values: [:])
        }
    }

    @Test func legacyFlowLaunchesOnSameRepo() async throws {
        let h = try Harness()
        let dir = h.root.appendingPathComponent("elsewhere/.flows")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("legacy.flow")
        let json = #"""
        {"formatVersion":1,"flow":{"name":"Fix","wires":[{"from":"issue","to":"plan","input":"issue"}],"nodes":[
        {"id":"issue","title":"Issue","kind":{"flowInput":{"_0":{"name":"issue","source":{"githubIssue":{}}}}},"position":{"x":0,"y":0}},
        {"id":"plan","title":"Plan","kind":{"prompt":{"_0":{"model":"sonnet","prompt":"LEGACYMARK {issue}","candidates":[],"allowedTools":[]}}},"position":{"x":1,"y":0}}]}}
        """#
        try Data(json.utf8).write(to: file)
        let flow = try FlowFile.load(from: file)
        h.agent.script({ $0.prompt.contains("LEGACYMARK") }, events: finished("ok"))
        let id = try await h.engine.launch(
            flow: flow, location: .repo(root: h.repo.url, file: file), values: ["issue": "7", "repo": h.repo.url.path])
        let run = await h.settled(id)
        #expect(run.status == .completed)
        #expect(run.repo == h.repo.url)
        #expect(run.title == "#7 Crash on launch")
        #expect(run.branch == "flow/7-crash-on-launch")
        #expect(h.agent.requests.first { $0.prompt.contains("LEGACYMARK") }?.prompt == "LEGACYMARK #7 Crash on launch\n\nBoom")
    }

    @Test func textInputKeepsTitle() async throws {
        let h = try Harness()
        let flow = Flow(name: "text", nodes: [
            repoNode(.exposed(default: nil)),
            Node(id: "task", title: "Task", kind: .flowInput(FlowInputConfig(name: "task", source: .text)), position: Point(x: 0, y: 1)),
            Node(id: "show", title: "Show", kind: .shell(ShellConfig(command: "echo {task}")), position: Point(x: 1, y: 0)),
        ], wires: [Wire(from: "task", to: "show", input: "task")])
        let text = String(repeating: "abcdefghij", count: 8)
        let id = try await h.engine.launch(flow: flow, location: .builtin, values: ["task": text, "repo": h.repo.url.path])
        let run = await h.settled(id)
        #expect(run.title == "abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij")
        #expect(run.title.count == 60)
        #expect(run.inputs["task"] == text)
        #expect(run.nodes[NodeKey(node: "show")]?.output?.contains(text) == true)
    }

    @Test func fixedFlowInputNeedsNoValue() async throws {
        let h = try Harness()
        let flow = Flow(name: "fixedtext", nodes: [
            repoNode(.exposed(default: nil)),
            Node(id: "task", title: "Task", kind: .flowInput(FlowInputConfig(name: "task", source: .text, binding: .fixed("do it"))),
                 position: Point(x: 0, y: 1)),
            Node(id: "show", title: "Show", kind: .shell(ShellConfig(command: "echo {task}")), position: Point(x: 1, y: 0)),
        ], wires: [Wire(from: "task", to: "show", input: "task")])
        let id = try await h.engine.launch(flow: flow, location: .builtin, values: ["repo": h.repo.url.path])
        let run = await h.settled(id)
        #expect(run.title == "do it")
        #expect(run.inputs["task"] == "do it")
        #expect(run.nodes[NodeKey(node: "show")]?.output?.contains("do it") == true)
    }

    @Test func preplanRunResumes() async throws {
        let h = try Harness()
        let first = try await {
            let id = try await h.engine.launch(flow: h.flow(), location: .builtin, values: ["issue": "7", "repo": h.repo.url.path])
            let run = await h.settled(id)
            await h.engine.waitForPass(id)
            return run
        }()
        let planPrompt = try #require(h.agent.requests.first { $0.prompt.contains("short numbered plan") }).prompt

        let url = try #require(Bundle.module.url(forResource: "preplan-run", withExtension: "json", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "__ID__", with: first.id.rawValue)
            .replacingOccurrences(of: "__REPO_URL__", with: first.repo.absoluteString)
            .replacingOccurrences(of: "__WORKTREE_URL__", with: first.worktree.absoluteString)
            .replacingOccurrences(of: "__REPO__", with: first.repo.path)
        let runsDir = h.root.appendingPathComponent("runs")
        try Data(text.utf8).write(to: runsDir.appendingPathComponent("\(first.id.rawValue).json"))

        let runner = RoutingRunner(gh: h.gh)
        let engine = RunEngine(store: h.store, runner: runner, agent: h.agent, issues: GitHubIssues(runner: runner))
        let restored = try await engine.restore()
        let old = try #require(restored.first { $0.id == first.id })
        #expect(old.nodes[NodeKey(node: "plan")]?.state == .interrupted)
        #expect(old.flow.repoNodes.count == 1, "the saved flow has no inputs; it still decodes")

        let before = h.agent.requests.count
        try await engine.resumeInterrupted(first.id)
        var settledRun: Run?
        for await run in engine.updates where run.id == first.id && run.status != .running { settledRun = run; break }
        let run = try #require(settledRun)
        #expect(run.status == .needsYou)
        #expect(run.nodes[NodeKey(node: "pick")]?.state == .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
        let resumed = h.agent.requests.dropFirst(before)
        #expect(resumed.first?.prompt.contains("Continue where you left off") == true || resumed.first?.prompt == planPrompt)
        let implement = try #require(resumed.first { $0.prompt.contains("Fix this GitHub issue") })
        #expect(implement.prompt.contains("PLAN: change the thing"))
        #expect(implement.prompt.contains("#7 Crash on launch"))
    }
}
