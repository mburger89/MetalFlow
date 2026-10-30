import Foundation

/// Runs agent sessions through the `claude` command line in headless mode.
public struct ClaudeCLI: AgentSession {
    private let runner: CommandRunner
    private let executable: String

    /// Appended to every session's system prompt so unattended agents can ask the user a question.
    public static let questionConvention = "You are running unattended inside MetalFlow. If you cannot continue without a decision from the user, stop and end your reply with one line starting QUESTION: followed by the question."

    /// Creates a session runner over `runner`.
    public init(runner: CommandRunner, executable: String = "claude") {
        self.runner = runner
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
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = ClaudeStreamParser()
                var finished = false
                do {
                    for try await line in lines {
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
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
