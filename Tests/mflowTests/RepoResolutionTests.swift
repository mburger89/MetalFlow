import Foundation
import Testing
import MetalFlowCore
@testable import mflow

/// Returns a canned result for every command and records them; no process is spawned.
private final class StubRunner: CommandRunner, @unchecked Sendable {
    let result: CommandResult
    private(set) var calls: [Command] = []
    init(_ result: CommandResult) { self.result = result }
    func run(_ c: Command) async throws -> CommandResult { calls.append(c); return result }
    func lines(_ c: Command) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
}

@Suite struct RepoResolutionTests {
    @Test func returnsTrimmedTopLevelAndAsksGitInTheGivenDirectory() async throws {
        let runner = StubRunner(CommandResult(exitCode: 0, stdout: "/work/repo\n", stderr: ""))
        let url = try await resolveRepo("/work/repo/sub/../sub", runner: runner)
        #expect(url.path == "/work/repo")
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].executable == "git")
        #expect(runner.calls[0].arguments == ["rev-parse", "--show-toplevel"])
        #expect(runner.calls[0].workingDirectory?.path == "/work/repo/sub")
    }

    @Test func notInsideARepositoryFailsNamingTheDirectory() async {
        let runner = StubRunner(CommandResult(exitCode: 128, stdout: "", stderr: "fatal: not a git repository"))
        do {
            _ = try await resolveRepo("/tmp/nowhere", runner: runner)
            Issue.record("expected a failure")
        } catch let e as CommandFailure {
            #expect(e.message == "/tmp/nowhere is not inside a git repository")
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func defaultsToTheCurrentDirectory() async throws {
        let runner = StubRunner(CommandResult(exitCode: 0, stdout: "/top\n", stderr: ""))
        _ = try await resolveRepo(nil, runner: runner)
        #expect(runner.calls[0].workingDirectory?.path == FileManager.default.currentDirectoryPath)
    }

    @Test func loadFlowReportsUnreadableFiles() {
        let url = URL(fileURLWithPath: "/nonexistent/x.flow")
        do { _ = try loadFlow(url); Issue.record("expected a failure") } catch let e as CommandFailure {
            #expect(e.message.hasPrefix("cannot load flow /nonexistent/x.flow: "))
        } catch { Issue.record("wrong error \(error)") }
    }
}
