import Foundation
import MetalFlowCore

func run() async -> Int32 {
    let argv = Array(CommandLine.arguments.dropFirst())
    guard let command = argv.first else {
        stderrPrint(usageText)
        return 64
    }
    let known: Set<String> = ["init-flow", "launch", "list", "show", "answer", "resume", "pick", "discard", "branch"]
    guard known.contains(command) else {
        stderrPrint("mflow: unknown command '\(command)'\n\n\(usageText)")
        return 64
    }
    do {
        let args = try parseArguments(Array(argv.dropFirst()))
        let resolver = ExecutableResolver()
        let runner = ProcessRunner(resolver: resolver)

        if command == "init-flow" {
            try requirePositionals(args, min: 0, max: 0, name: command)
            let repo = try await resolveRepo(args.repo, runner: runner)
            let file = repo.appendingPathComponent(FlowFile.directoryName).appendingPathComponent("fix-issue.flow")
            guard !FileManager.default.fileExists(atPath: file.path) else {
                throw CommandFailure(message: "\(file.path) already exists; not overwriting")
            }
            try FlowFile.save(BuiltinFlows.fixGitHubIssue, to: file)
            print("wrote \(file.path)")
            return 0
        }

        let path = await resolver.searchPath().joined(separator: ":")
        let engine = RunEngine(
            store: RunStore(root: storeRoot()), runner: runner, agent: ClaudeCLI(runner: runner),
            issues: GitHubIssues(runner: runner), shellEnvironment: ["PATH": path])
        let runs = try await engine.restore()

        switch command {
        case "launch":
            try requirePositionals(args, min: 1, max: 1, name: command)
            let repo = try await resolveRepo(args.repo, runner: runner)
            let flowURL = args.flow.map { URL(fileURLWithPath: $0) }
                ?? repo.appendingPathComponent(FlowFile.directoryName).appendingPathComponent("fix-issue.flow")
            let flow: Flow
            do { flow = try FlowFile.load(from: flowURL) } catch {
                throw CommandFailure(message: "cannot load flow \(flowURL.path): \(error)")
            }
            let id = try await engine.launch(flow: flow, repo: repo, input: args.positionals[0])
            print(id.rawValue)
            return await follow(engine: engine, id: id, seed: nil)

        case "list":
            try requirePositionals(args, min: 0, max: 0, name: command)
            let sorted = runs.sorted { $0.createdAt > $1.createdAt }
            if sorted.isEmpty { print("no runs") }
            for r in sorted { print("\(r.id.rawValue)  \(statusText(r.status))  \(r.title)") }
            return 0

        case "show":
            try requirePositionals(args, min: 1, max: 1, name: command)
            let id = try parseRunID(args.positionals[0])
            guard let r = await engine.run(id) else { throw CommandFailure(message: "no run \(id.rawValue)") }
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

        case "resume":
            try requirePositionals(args, min: 1, max: 1, name: command)
            let id = try parseRunID(args.positionals[0])
            let seed = await engine.run(id)
            try await engine.resumeInterrupted(id)
            return await follow(engine: engine, id: id, seed: seed)

        case "pick":
            try requirePositionals(args, min: 2, max: 2, name: command)
            let id = try parseRunID(args.positionals[0])
            let result = try await engine.pick(id, lane: args.positionals[1])
            print(mergeResultText(result))
            if case .merged = result { return 0 }
            return 1

        case "discard":
            try requirePositionals(args, min: 1, max: 1, name: command)
            let id = try parseRunID(args.positionals[0])
            try await engine.discard(id)
            print("discarded \(id.rawValue)")
            return 0

        default: // branch
            try requirePositionals(args, min: 3, max: 3, name: command)
            let id = try parseRunID(args.positionals[0])
            try await engine.branchFromHere(id, lane: args.positionals[1], name: args.positionals[2])
            print("kept branch \(args.positionals[2])")
            return 0
        }
    } catch let e as UsageError {
        stderrPrint("mflow: \(e.message)\n\n\(usageText)")
        return 64
    } catch let e as CommandFailure {
        stderrPrint("mflow: \(e.message)")
        return 1
    } catch {
        stderrPrint("mflow: \(error)")
        return 1
    }
}

exit(await run())
