import Foundation
import os
@testable import MetalFlowCore

/// Records every command a `RoutingRunner` sees and lets a test answer some of them itself.
final class CommandHooks: Sendable {
    struct Override: Sendable {
        var match: @Sendable (Command) -> Bool
        var run: @Sendable (Command) async throws -> CommandResult
    }

    private struct State {
        var calls: [Command] = []
        var overrides: [Override] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Every command seen, in order.
    var calls: [Command] { state.withLock { $0.calls } }

    /// The calls to `git <subcommand> ...` (after `-C <path>`), as the arguments from the subcommand on.
    func gitCalls(_ subcommand: String) -> [[String]] {
        calls.filter { $0.executable == "git" }.map(Self.gitArguments).filter { $0.first == subcommand }
    }

    /// The calls to `gh`, as their arguments.
    func ghCalls() -> [[String]] { calls.filter { $0.executable == "gh" }.map(\.arguments) }

    /// `git`'s arguments without the leading `-C <path>`.
    static func gitArguments(_ c: Command) -> [String] {
        c.arguments.first == "-C" ? Array(c.arguments.dropFirst(2)) : c.arguments
    }

    /// Answers commands matching `match` (the latest registered override wins) instead of running them.
    func override(_ match: @escaping @Sendable (Command) -> Bool, _ run: @escaping @Sendable (Command) async throws -> CommandResult) {
        state.withLock { $0.overrides.append(Override(match: match, run: run)) }
    }

    /// Answers `git <subcommand> ...` with a fixed result.
    func stubGit(_ subcommand: String, exit: Int32 = 0, stdout: String = "", stderr: String = "") {
        override({ $0.executable == "git" && Self.gitArguments($0).first == subcommand }) { _ in
            CommandResult(exitCode: exit, stdout: stdout, stderr: stderr)
        }
    }

    func record(_ c: Command) -> Override? {
        state.withLock { s in
            s.calls.append(c)
            return s.overrides.last { $0.match(c) }
        }
    }
}

/// Routes `gh` to a fake and everything else to real processes, unless a test's hooks answer first.
struct RoutingRunner: CommandRunner {
    let gh: FakeCommandRunner
    var hooks = CommandHooks()
    let process = ProcessRunner(resolver: ExecutableResolver(searchPath: ["/usr/bin", "/bin", "/opt/homebrew/bin", "/usr/local/bin"]))

    private func target(_ c: Command) -> any CommandRunner {
        c.executable == "gh" ? gh : process
    }

    func run(_ c: Command) async throws -> CommandResult {
        if let override = hooks.record(c) { return try await override.run(c) }
        return try await target(c).run(c)
    }

    func lines(_ c: Command) -> AsyncThrowingStream<String, Error> {
        _ = hooks.record(c)
        return target(c).lines(c)
    }
}
