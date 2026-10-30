import Foundation
import Testing
@testable import MetalFlowCore

struct CommandRunnerTests {
    private func runner() -> ProcessRunner {
        ProcessRunner(resolver: ExecutableResolver(searchPath: ["/bin", "/usr/bin"]))
    }

    @Test func runCapturesStdoutAndExitCode() async throws {
        let result = try await runner().run(Command(executable: "/bin/sh", arguments: ["-c", "echo hi; exit 3"]))
        #expect(result.stdout == "hi\n")
        #expect(result.exitCode == 3)
        #expect(!result.succeeded)
    }

    @Test func runCapturesStderrWithoutDeadlock() async throws {
        let result = try await runner().run(Command(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 300000 /dev/zero >&2; echo done"]))
        #expect(result.stderr.utf8.count == 300000)
        #expect(result.stdout == "done\n")
    }

    @Test func linesStreamsEachLine() async throws {
        var got: [String] = []
        for try await line in runner().lines(Command(executable: "printf", arguments: ["a\\nb\\n"])) {
            got.append(line)
        }
        #expect(got == ["a", "b"])
    }

    @Test func linesThrowsOnFailure() async throws {
        let cmd = Command(executable: "/bin/sh", arguments: ["-c", "echo x; echo oops >&2; exit 2"])
        var got: [String] = []
        do {
            for try await line in runner().lines(cmd) { got.append(line) }
            Issue.record("expected throw")
        } catch let error as CommandError {
            #expect(error == .failed(cmd, exitCode: 2, stderr: "oops\n"))
        }
        #expect(got == ["x"])
    }

    @Test func missingExecutableThrows() async throws {
        let r = ProcessRunner(resolver: ExecutableResolver(searchPath: ["/nonexistent"]))
        await #expect(throws: CommandError.executableNotFound("nope")) {
            try await r.run(Command(executable: "nope", arguments: []))
        }
    }

    @Test func checkThrowsOnNonZero() async throws {
        let cmd = Command(executable: "/bin/sh", arguments: ["-c", "exit 4"])
        await #expect(throws: CommandError.failed(cmd, exitCode: 4, stderr: "")) {
            try await runner().check(cmd)
        }
    }

    @Test func cancellationTerminatesProcess() async throws {
        let r = runner()
        let task = Task { () -> [String] in
            var got: [String] = []
            do {
                for try await line in r.lines(Command(executable: "/bin/sh", arguments: ["-c", "echo started; exec sleep 30"])) {
                    got.append(line)
                    // The process is definitely running now; cancel and keep draining
                    // until the stream ends, which only happens once the process has exited.
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            } catch {}
            return got
        }
        let got = await task.value
        #expect(got == ["started"])
    }

    @Test func resolverFindsInSearchPath() async throws {
        let url = try await ExecutableResolver(searchPath: ["/nonexistent", "/bin"]).resolve("sh")
        #expect(url.path == "/bin/sh")
    }
}
