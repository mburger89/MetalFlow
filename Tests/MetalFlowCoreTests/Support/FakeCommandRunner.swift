import Foundation
import os
@testable import MetalFlowCore

/// Scriptable `CommandRunner` for tests. The latest-registered matching stub wins.
final class FakeCommandRunner: CommandRunner {
    private struct Stub {
        var executable: String
        var argsPrefix: [String]
        var result: CommandResult
        var lines: [String]
    }

    private struct State {
        var stubs: [Stub] = []
        var calls: [Command] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Every command passed to `run` or `lines`, in order.
    var calls: [Command] { state.withLock { $0.calls } }

    func stub(_ executable: String, _ argsPrefix: [String], result: CommandResult) {
        var parts = result.stdout.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        let lines = parts
        state.withLock { $0.stubs.append(Stub(executable: executable, argsPrefix: argsPrefix, result: result, lines: lines)) }
    }

    func stubLines(_ executable: String, _ argsPrefix: [String], lines: [String], exitCode: Int32 = 0) {
        let result = CommandResult(exitCode: exitCode, stdout: lines.map { $0 + "\n" }.joined(), stderr: "")
        state.withLock { $0.stubs.append(Stub(executable: executable, argsPrefix: argsPrefix, result: result, lines: lines)) }
    }

    private func match(_ c: Command) throws -> Stub {
        let found: Stub? = state.withLock { s in
            s.calls.append(c)
            return s.stubs.last { $0.executable == c.executable && c.arguments.starts(with: $0.argsPrefix) }
        }
        guard let found else { throw CommandError.executableNotFound(c.executable) }
        return found
    }

    func run(_ c: Command) async throws -> CommandResult {
        try match(c).result
    }

    func lines(_ c: Command) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            do {
                let stub = try match(c)
                for line in stub.lines { continuation.yield(line) }
                if stub.result.exitCode != 0 {
                    continuation.finish(throwing: CommandError.failed(c, exitCode: stub.result.exitCode, stderr: stub.result.stderr))
                } else {
                    continuation.finish()
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
