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

    @Test func linesKeepsUnterminatedLastLine() async throws {
        var got: [String] = []
        for try await line in runner().lines(Command(executable: "printf", arguments: ["a\\nb"])) {
            got.append(line)
        }
        #expect(got == ["a", "b"])
    }

    @Test func nonexistentWorkingDirectoryIsLaunchFailure() async throws {
        let cmd = Command(executable: "/bin/sh", arguments: ["-c", "true"],
                          workingDirectory: URL(fileURLWithPath: "/nonexistent-dir-for-test"))
        do {
            _ = try await runner().run(cmd)
            Issue.record("expected throw")
        } catch let error as CommandError {
            guard case .launchFailed = error else { Issue.record("wrong error \(error)"); return }
        }
    }

    /// Runs `script` with `$1` = a fifo, cancels once the script has written a pid to it,
    /// and returns that pid after `run` has finished with CancellationError.
    private func cancelRun(script: String) async throws -> pid_t {
        let fifo = FileManager.default.temporaryDirectory.appendingPathComponent("mf-\(UUID().uuidString).fifo").path
        #expect(mkfifo(fifo, 0o600) == 0)
        defer { unlink(fifo) }
        let r = runner()
        let task = Task { try await r.run(Command(executable: "/bin/sh", arguments: ["-c", script, "sh", fifo])) }
        let pidText = await Task.detached { () -> String in
            guard let h = FileHandle(forReadingAtPath: fifo) else { return "" }
            return String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        }.value
        let pid = try #require(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        return pid
    }

    /// Waits (bounded, yielding) for a pid to disappear; zombies linger briefly before launchd reaps them.
    private func gone(_ pid: pid_t) async -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            await Task.yield()
        }
        return kill(pid, 0) == -1 && errno == ESRCH
    }

    @Test func cancellationTerminatesProcess() async throws {
        let pid = try await cancelRun(script: "echo $$ > \"$1\"; exec sleep 30")
        #expect(await gone(pid))
    }

    @Test func cancellationKillsDescendants() async throws {
        let pid = try await cancelRun(script: "sleep 30 & echo $! > \"$1\"; wait")
        #expect(await gone(pid))
    }

    @Test func resolverFindsInSearchPath() async throws {
        let url = try await ExecutableResolver(searchPath: ["/nonexistent", "/bin"]).resolve("sh")
        #expect(url.path == "/bin/sh")
    }
}
