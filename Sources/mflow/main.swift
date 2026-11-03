import Foundation
import MetalFlowCore

func run() async -> Int32 {
    // Line-buffer stdout so a run id reaches a pipe or file as soon as it is printed.
    setvbuf(stdout, nil, _IOLBF, 0)
    let argv = Array(CommandLine.arguments.dropFirst())
    if let message = commandLineProblem(argv) {
        stderrPrint(message)
        return 64
    }
    let command = argv[0]
    do {
        let args = try parseArguments(Array(argv.dropFirst()))
        let resolver = ExecutableResolver()
        let runner = ProcessRunner(resolver: resolver)

        if command == "init-flow" {
            try requirePositionals(args, min: 0, max: 0, name: command)
            let repo = try await resolveRepo(args.repo, runner: runner)
            let file = repo.appendingPathComponent(FlowFile.directoryName).appendingPathComponent("fix-issue.flow")
            try checkInitFlowTarget(file, force: args.force)
            let (prepared, _) = FlowCatalog.prepareForSave(
                BuiltinFlows.fixGitHubIssue, destination: FlowLocation.of(file: file), origin: repo)
            try FlowFile.save(prepared, to: file)
            print("wrote \(file.path)")
            return 0
        }

        let path = await resolver.searchPath().joined(separator: ":")
        let store = RunStore(root: storeRoot())
        let engine = RunEngine(
            store: store, runner: runner, agent: ClaudeCLI(runner: runner),
            issues: GitHubIssues(runner: runner), maxSessions: store.settings().maxSessions,
            shellEnvironment: ["PATH": path])
        let runs = try await engine.restore()

        switch command {
        case "launch":
            try requirePositionals(args, min: 0, max: 1, name: command)
            let store = RunStore(root: storeRoot())
            let cwdRepo: URL?
            var cwdError: Error?
            if args.repo != nil { cwdRepo = try await resolveRepo(args.repo, runner: runner) } else {
                do { cwdRepo = try await resolveRepo(nil, runner: runner) } catch { cwdRepo = nil; cwdError = error }
            }
            let (flow, location) = try selectFlow(
                flowArgument: args.flow, cwdRepo: cwdRepo, library: store.flowsDirectory, repos: store.knownRepos())
            let values = try launchValues(flow: flow, location: location, args: args, cwdRepo: cwdRepo, cwdError: cwdError)
            let id: RunID
            do { id = try await engine.launch(flow: flow, location: location, values: values) } catch let e as RunEngineError {
                if case .launch(let le) = e { throw CommandFailure(message: flow.message(for: le)) }
                throw CommandFailure(message: e.localizedDescription)
            }
            print(id.rawValue)
            return await follow(engine: engine, id: id, seed: nil)

        case "list":
            try requirePositionals(args, min: 0, max: 0, name: command)
            let sorted = runs.sorted { $0.createdAt > $1.createdAt }
            if sorted.isEmpty { print("no runs") }
            for r in sorted {
                let status = await engine.isRunningElsewhere(r.id) ? "running in another mflow" : statusText(r.status)
                print("\(r.id.rawValue)  \(status)  \(r.title)")
            }
            return 0

        case "show":
            try requirePositionals(args, min: 1, max: 1, name: command)
            let id = try parseRunID(args.positionals[0])
            guard let r = await engine.run(id) else { throw CommandFailure(message: "no run \(id.rawValue)") }
            if await engine.isRunningElsewhere(id) { print("running in another mflow") }
            for line in runSummary(r) { print(line) }
            return 0

        case "answer":
            try requirePositionals(args, min: 3, name: command)
            let id = try parseRunID(args.positionals[0])
            guard let key = NodeKey(description: args.positionals[1]) else {
                throw CommandFailure(message: "'\(args.positionals[1])' is not a node key (use node or node@lane)")
            }
            let seed = await engine.run(id)
            try await engine.answer(id, node: key, reply: args.positionals.dropFirst(2).joined(separator: " "),
                                    allowTools: args.allow)
            return await follow(engine: engine, id: id, seed: seed)

        case "follow-up":
            try rejectOptions(args, for: command)
            try requirePositionals(args, min: 3, name: command)
            let id = try parseRunID(args.positionals[0])
            guard let key = NodeKey(description: args.positionals[1]) else {
                throw CommandFailure(message: "'\(args.positionals[1])' is not a node key (use node or node@lane)")
            }
            let seed = await engine.run(id)
            try await engine.followUp(id, node: key, message: args.positionals.dropFirst(2).joined(separator: " "))
            return await follow(engine: engine, id: id, seed: seed)

        case "resume":
            try requirePositionals(args, min: 1, max: 1, name: command)
            let id = try parseRunID(args.positionals[0])
            let seed = await engine.run(id)
            try await engine.resumeInterrupted(id)
            return await follow(engine: engine, id: id, seed: seed)

        case "pick":
            try requirePositionals(args, min: 2, max: 2, name: command)
            let id = try parseRunID(args.positionals[0])
            let seed = await engine.run(id)
            let result = try await uninterruptible { try await engine.pick(id, lane: args.positionals[1]) }
            if case .handedToPullRequest = result {
                // The run carries on to open the pull request: follow it (Ctrl-C cancels), then say where it is.
                let code = await follow(engine: engine, id: id, seed: seed)
                if let line = pullRequestLine(await engine.run(id)) { print(line) }
                return code
            }
            print(mergeResultText(result))
            if case .merged = result { return 0 }
            return 1

        case "discard":
            try requirePositionals(args, min: 1, max: 1, name: command)
            let id = try parseRunID(args.positionals[0])
            try await uninterruptible { try await engine.discard(id) }
            print("discarded \(id.rawValue)")
            return 0

        default: // branch
            try requirePositionals(args, min: 3, max: 3, name: command)
            let id = try parseRunID(args.positionals[0])
            try await uninterruptible {
                try await engine.branchFromHere(id, lane: args.positionals[1], name: args.positionals[2])
            }
            print("kept branch \(args.positionals[2])")
            return 0
        }
    } catch {
        let (code, message) = failureReport(error)
        stderrPrint(message)
        return code
    }
}

exit(await run())
