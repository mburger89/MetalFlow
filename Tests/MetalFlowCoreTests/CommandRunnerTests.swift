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

    /// Reads a pid from a fifo without ever blocking on open: bounded yield loop (about 5 s).
    private func readPid(fifo: String) async -> pid_t? {
        let fd = open(fifo, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var text = ""
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var buf = [UInt8](repeating: 0, count: 64)
            let n = read(fd, &buf, buf.count)
            if n > 0 { text += String(decoding: buf[0..<n], as: UTF8.self) }
            if text.hasSuffix("\n") { return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            await Task.yield()
        }
        return nil
    }

    /// Starts a child via `launch` with `$1` = a fifo, waits for its script to report a pid,
    /// then cancels. Returns the pid and the time from cancel() until `finished` returned.
    private func cancelled(
        script: String,
        launch: (ProcessRunner, Command) -> Task<Void, Error>,
        finished: (Task<Void, Error>, pid_t) async -> Void
    ) async throws -> (pid: pid_t, elapsed: Duration) {
        let fifo = FileManager.default.temporaryDirectory.appendingPathComponent("mf-\(UUID().uuidString).fifo").path
        try #require(mkfifo(fifo, 0o600) == 0)
        defer { unlink(fifo) }
        let task = launch(runner(), Command(executable: "/bin/sh", arguments: ["-c", script, "sh", fifo]))
        defer { task.cancel() }
        let pid = try #require(await readPid(fifo: fifo))
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        await finished(task, pid)
        return (pid, start.duration(to: clock.now))
    }

    private func runTask(_ r: ProcessRunner, _ c: Command) -> Task<Void, Error> {
        Task { _ = try await r.run(c) }
    }

    private func runCancelled(script: String) async throws -> (pid: pid_t, elapsed: Duration) {
        try await cancelled(script: script, launch: runTask) { task, _ in
            await #expect(throws: CancellationError.self) { try await task.value }
        }
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
        let (pid, elapsed) = try await runCancelled(script: "echo $$ > \"$1\"; exec sleep 60")
        #expect(elapsed < .seconds(10))
        #expect(await gone(pid))
    }

    @Test func cancellationKillsDescendants() async throws {
        let (pid, elapsed) = try await runCancelled(script: "sleep 60 & echo $! > \"$1\"; wait")
        #expect(elapsed < .seconds(10))
        #expect(await gone(pid))
    }

    @Test func cancellingLinesConsumerTerminatesProcess() async throws {
        let (pid, elapsed) = try await cancelled(
            script: "echo $$ > \"$1\"; exec sleep 60",
            launch: { r, c in Task { for try await _ in r.lines(c) {} } },
            finished: { task, pid in
                _ = await task.result
                _ = await gone(pid)
            })
        #expect(elapsed < .seconds(10))
        #expect(await gone(pid))
    }

    @Test func resolverFindsInSearchPath() async throws {
        let url = try await ExecutableResolver(searchPath: ["/nonexistent", "/bin"]).resolve("sh")
        #expect(url.path == "/bin/sh")
    }
}
