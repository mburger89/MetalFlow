import Foundation

/// A session that produced no stream event within the startup timeout.
struct ClaudeStartupTimeout: Error, LocalizedError {
    let duration: Duration

    /// "claude did not respond within N seconds of starting".
    var errorDescription: String? {
        let c = duration.components
        let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
        return "claude did not respond within \(String(format: "%g", seconds)) seconds of starting"
    }
}

/// Tracks whether a session has produced any output yet.
private final class FirstEventFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = false
    var isSet: Bool { lock.withLock { seen } }
    func set() { lock.withLock { seen = true } }
}

/// Runs agent sessions through the `claude` command line in headless mode.
public struct ClaudeCLI: AgentSession {
    private let runner: CommandRunner
    private let executable: String
    private let startupTimeout: Duration

    /// Appended to every session's system prompt so unattended agents can ask the user a question.
    public static let questionConvention = "You are running unattended inside MetalFlow. If you cannot continue without a decision from the user, stop and end your reply with one line starting QUESTION: followed by the question."

    /// Creates a session runner over `runner`.
    /// A session that emits nothing within `startupTimeout` is terminated and fails; later silence is not limited.
    public init(runner: CommandRunner, executable: String = "claude", startupTimeout: Duration = .seconds(60)) {
        self.runner = runner
        self.startupTimeout = startupTimeout
        self.executable = executable
    }

    /// Builds the `claude` command for a request.
    func command(for r: AgentRequest) -> Command {
        var args = ["-p", r.prompt, "--output-format", "stream-json", "--verbose", "--permission-mode", "default",
                    "--model", r.model, "--allowedTools", r.allowedTools.joined(separator: ",")]
        if let maxTurns = r.maxTurns { args += ["--max-turns", String(maxTurns)] }
        if let id = r.resumeSessionID { args += ["--resume", id] }
        args += ["--append-system-prompt", Self.questionConvention]
        return Command(executable: executable, arguments: args, workingDirectory: r.workingDirectory)
    }

    /// Streams the session's events. Cancelling the consumer cancels the underlying process stream.
    /// A non-zero exit after a `result` line is not an error; without one it throws.
    public func run(_ r: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        let lines = runner.lines(command(for: r))
        let timeout = startupTimeout
        return AsyncThrowingStream { continuation in
            let gotEvent = FirstEventFlag()
            let task = Task {
                var parser = ClaudeStreamParser()
                var finished = false
                do {
                    for try await line in lines {
                        gotEvent.set()
                        for event in try parser.parse(line: line) {
                            if case .finished = event { finished = true }
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    if finished, case CommandError.failed = error {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, !gotEvent.isSet else { return }
                task.cancel()
                continuation.finish(throwing: ClaudeStartupTimeout(duration: timeout))
            }
            continuation.onTermination = { _ in task.cancel(); watchdog.cancel() }
        }
    }
}
