import Foundation
import Testing
import MetalFlowCore
@testable import mflow

private func repoNode(_ mode: RepoMode) -> Node {
    Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: mode)), position: Point(x: 0, y: 0))
}
private func input(_ name: String) -> Node {
    Node(id: NodeID(rawValue: name), title: name, kind: .flowInput(FlowInputConfig(name: name, source: .text)), position: Point(x: 0, y: 0))
}
private func flow(_ name: String, _ mode: RepoMode, inputs: [String] = []) -> Flow {
    Flow(name: name, nodes: inputs.map(input) + [repoNode(mode)], wires: [])
}
private struct Boom: Error, LocalizedError { var errorDescription: String? { "not a repo" } }

/// A temporary directory removed on deinit.
private final class Scratch: Sendable {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mflow-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func dir(_ name: String) throws -> URL {
        let d = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    @discardableResult func save(_ flow: Flow, to path: String) throws -> URL {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FlowFile.save(flow, to: file)
        return file
    }
}

@Suite struct SelectFlowTests {
    @Test func noFlowNoRepoFileUsesBuiltin() throws {
        let s = try Scratch()
        let (f, loc) = try selectFlow(flowArgument: nil, cwdRepo: try s.dir("repo"), library: try s.dir("lib"), repos: [])
        #expect(f.name == BuiltinFlows.fixGitHubIssue.name && loc == .builtin)
        let (_, loc2) = try selectFlow(flowArgument: nil, cwdRepo: nil, library: try s.dir("lib"), repos: [])
        #expect(loc2 == .builtin)
    }

    @Test func noFlowPicksTheRepoFixIssueFlow() throws {
        let s = try Scratch()
        let file = try s.save(flow("Mine", .thisRepo), to: "repo/.flows/fix-issue.flow")
        let (f, loc) = try selectFlow(flowArgument: nil, cwdRepo: s.url.appendingPathComponent("repo"), library: try s.dir("lib"), repos: [])
        #expect(f.name == "Mine")
        #expect(loc == FlowLocation.of(file: file))
        if case .repo = loc {} else { Issue.record("expected a repo location") }
    }

    @Test func flowArgumentThatIsAFileIsLoadedDirectly() throws {
        let s = try Scratch()
        let file = try s.save(flow("Direct", .exposed(default: nil)), to: "elsewhere/x.flow")
        let (f, loc) = try selectFlow(flowArgument: file.path, cwdRepo: nil, library: try s.dir("lib"), repos: [])
        #expect(f.name == "Direct" && loc == .library(file: file))
    }

    @Test func flowArgumentNamesALibraryFlowIgnoringCase() throws {
        let s = try Scratch()
        let lib = try s.dir("lib")
        let file = try s.save(flow("Release Notes", .exposed(default: nil)), to: "lib/rn.flow")
        let (f, loc) = try selectFlow(flowArgument: "release NOTES", cwdRepo: nil, library: lib, repos: [])
        #expect(f.name == "Release Notes")
        guard case .library(let found) = loc else { Issue.record("expected a library location"); return }
        #expect(found.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)
    }

    @Test func flowArgumentNamesTheBuiltinAndKnownRepoFlows() throws {
        let s = try Scratch()
        let (b, bl) = try selectFlow(flowArgument: BuiltinFlows.fixGitHubIssue.name.lowercased(), cwdRepo: nil, library: try s.dir("lib"), repos: [])
        #expect(b.name == BuiltinFlows.fixGitHubIssue.name && bl == .builtin)
        try s.save(flow("Repo Flow", .thisRepo), to: "known/.flows/a.flow")
        let (r, rl) = try selectFlow(flowArgument: "repo flow", cwdRepo: nil, library: try s.dir("lib"), repos: [s.url.appendingPathComponent("known")])
        #expect(r.name == "Repo Flow")
        if case .repo = rl {} else { Issue.record("expected a repo location") }
    }

    @Test func unknownAndAmbiguousNamesFail() throws {
        let s = try Scratch()
        let lib = try s.dir("lib")
        #expect(throws: LaunchArgumentError.noFlowNamed("ghost")) {
            _ = try selectFlow(flowArgument: "ghost", cwdRepo: nil, library: lib, repos: [])
        }
        try s.save(flow("Twin", .exposed(default: nil)), to: "lib/a.flow")
        try s.save(flow("Twin", .exposed(default: nil)), to: "lib/b.flow")
        do { _ = try selectFlow(flowArgument: "twin", cwdRepo: nil, library: lib, repos: []); Issue.record("expected a failure") }
        catch let e as LaunchArgumentError {
            if case .ambiguousFlow("twin", let paths) = e { #expect(paths.count == 2) } else { Issue.record("wrong error \(e)") }
        }
    }

    @Test func unloadableFlowFileReportsPath() throws {
        let s = try Scratch()
        let bad = s.url.appendingPathComponent("bad.flow")
        try Data("not json".utf8).write(to: bad)
        do { _ = try selectFlow(flowArgument: bad.path, cwdRepo: nil, library: s.url, repos: []); Issue.record("expected a failure") }
        catch let e as CommandFailure { #expect(e.message.hasPrefix("cannot load flow \(bad.path): ")) }
    }

    @Test func knownReposAreNotListedForAFileArgument() throws {
        let s = try Scratch()
        let file = try s.save(flow("Direct", .exposed(default: nil)), to: "x.flow")
        func boom() -> [URL] { Issue.record("repos evaluated"); return [] }
        _ = try selectFlow(flowArgument: file.path, cwdRepo: nil, library: s.url, repos: boom())
    }
}

@Suite struct LaunchValuesTests {
    private let cwd = URL(fileURLWithPath: "/work/repo")
    private func values(_ f: Flow, _ loc: FlowLocation = .builtin, _ args: Arguments = Arguments(),
                        cwdRepo: URL? = URL(fileURLWithPath: "/work/repo"), cwdError: Error? = nil) throws -> [String: String] {
        try launchValues(flow: f, location: loc, args: args, cwdRepo: cwdRepo, cwdError: cwdError)
    }

    @Test func positionalFillsFirstNonRepoInputAndCwdFillsExposedRepo() throws {
        var a = Arguments(); a.positionals = ["7"]
        #expect(try values(BuiltinFlows.fixGitHubIssue, .builtin, a) == ["issue": "7", "repo": "/work/repo"])
    }

    @Test func positionalGoesToTheFirstInputInPlanOrder() throws {
        var a = Arguments(); a.positionals = ["v"]
        #expect(try values(flow("f", .exposed(default: nil), inputs: ["alpha", "beta"]), .unsaved, a)
                == ["alpha": "v", "repo": "/work/repo"])
    }

    @Test func setFillsAnyInputAndWinsOverPositional() throws {
        var a = Arguments(); a.positionals = ["p"]; a.sets = [("alpha", "s"), ("beta", "b")]
        #expect(try values(flow("f", .exposed(default: nil), inputs: ["alpha", "beta"]), .unsaved, a)
                == ["alpha": "s", "beta": "b", "repo": "/work/repo"])
    }

    @Test func unknownSetAndSurplusPositionalFail() {
        var a = Arguments(); a.sets = [("nope", "1")]
        #expect(throws: LaunchArgumentError.unknownInput("nope")) { _ = try values(BuiltinFlows.fixGitHubIssue, .builtin, a) }
        var b = Arguments(); b.positionals = ["x"]
        #expect(throws: LaunchArgumentError.noFieldForValue) { _ = try values(flow("f", .exposed(default: nil)), .unsaved, b) }
    }

    @Test func explicitRepoSetBeatsTheCurrentDirectory() throws {
        var a = Arguments(); a.sets = [("repo", "/other")]
        #expect(try values(flow("f", .exposed(default: nil)), .unsaved, a) == ["repo": "/other"])
    }

    @Test func notInARepoThrowsTheReasonWhenRepoIsRequired() {
        do { _ = try values(BuiltinFlows.fixGitHubIssue, .builtin, Arguments(), cwdRepo: nil, cwdError: Boom()); Issue.record("expected a failure") }
        catch { #expect(error is Boom) }
    }

    @Test func notInARepoIsFineWithADefaultOrAnExplicitRepo() throws {
        #expect(try values(flow("f", .exposed(default: "/d")), .unsaved, Arguments(), cwdRepo: nil, cwdError: Boom()) == [:])
        var a = Arguments(); a.sets = [("repo", "/x")]
        #expect(try values(flow("f", .exposed(default: nil)), .unsaved, a, cwdRepo: nil, cwdError: Boom()) == ["repo": "/x"])
    }

    @Test func boundFlowIgnoresCwdButTakesAnExplicitRepo() throws {
        let root = URL(fileURLWithPath: "/work/repo")
        let loc = FlowLocation.repo(root: root, file: root.appendingPathComponent(".flows/a.flow"))
        let bound = flow("f", .thisRepo)
        #expect(try values(bound, loc) == [:])
        var a = Arguments(); a.repo = "/work/other"
        // The engine compares this against the bound repo and refuses a mismatch ("this flow always runs on ...").
        #expect(try values(bound, loc, a, cwdRepo: URL(fileURLWithPath: "/work/other")) == ["repo": "/work/other"])
        #expect(try values(flow("g", .fixed(path: "/fixed")), .unsaved, a, cwdRepo: URL(fileURLWithPath: "/work/other"))
                == ["repo": "/work/other"])
        #expect(try values(flow("g", .fixed(path: "/fixed")), .unsaved) == [:])
    }

    @Test func invalidFlowBecomesACommandFailure() {
        let none = Flow(name: "f", nodes: [], wires: [])
        do { _ = try values(none); Issue.record("expected a failure") }
        catch let e as CommandFailure { #expect(e.message == none.message(for: LaunchError.noRepoNode)) }
        catch { Issue.record("wrong error \(error)") }
    }

    @Test func thisRepoOutsideARepoLocationFails() {
        do { _ = try values(flow("f", .thisRepo), .unsaved); Issue.record("expected a failure") }
        catch is CommandFailure {} catch { Issue.record("wrong error \(error)") }
    }
}

@Suite struct DispatchTests {
    @Test func noCommandPrintsUsage() {
        #expect(commandLineProblem([]) == usageText)
    }

    @Test func unknownCommandNamesItAndPrintsUsage() {
        #expect(commandLineProblem(["frobnicate", "x"]) == "mflow: unknown command 'frobnicate'\n\n\(usageText)")
        #expect(commandLineProblem(["--help"])?.hasPrefix("mflow: unknown command '--help'") == true)
        #expect(commandLineProblem(["LIST"]) != nil)
    }

    @Test func knownCommandsPass() {
        for c in knownCommands { #expect(commandLineProblem([c]) == nil) }
        #expect(knownCommands.count == 9)
    }

    @Test func failureReportMapsErrorsToExitCodes() {
        #expect(failureReport(LaunchArgumentError.badSet("x")) == (64, "mflow: expected --set name=value, got 'x'\n\n\(usageText)"))
        #expect(failureReport(LaunchArgumentError.unknownInput("n")) == (1, "mflow: the flow has no input named 'n'"))
        #expect(failureReport(UsageError(message: "oops")) == (64, "mflow: oops\n\n\(usageText)"))
        #expect(failureReport(CommandFailure(message: "bad")) == (1, "mflow: bad"))
        #expect(failureReport(Boom()) == (1, "mflow: not a repo"))
    }
}
