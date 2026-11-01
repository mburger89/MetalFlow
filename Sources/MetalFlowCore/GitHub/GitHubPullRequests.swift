import Foundation

/// Failures from opening a pull request.
public enum PullRequestError: Error, Equatable {
    /// `gh` exited with an error; carries its stderr (or a note when it printed none).
    case failed(String)
    /// `gh` reported success but printed no URL.
    case noURL
}

extension PullRequestError: LocalizedError {
    /// A readable message including `gh`'s stderr.
    public var errorDescription: String? {
        switch self {
        case .failed(let stderr): return "gh pr create failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .noURL: return "gh pr create succeeded but printed no pull request URL"
        }
    }
}

/// Opens pull requests through the `gh` CLI.
public struct GitHubPullRequests: Sendable {
    private let runner: any CommandRunner

    /// Creates a client that runs `gh` through `runner`.
    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    /// Opens a pull request for `head` into `base` with `gh` run in `repo`, and returns its URL.
    ///
    /// A pull request that already exists for the branch counts as success: its URL is taken from `gh`'s message,
    /// or looked up with `gh pr view`. Arguments are passed as separate argv entries, never through a shell.
    public func create(repo: URL, base: String, head: String, title: String, body: String, draft: Bool) async throws -> String {
        var arguments = ["pr", "create", "--base", base, "--head", head, "--title", title, "--body", body]
        if draft { arguments.append("--draft") }
        let result = try await runner.run(Command(
            executable: "gh", arguments: arguments, workingDirectory: repo, environment: ["GH_PROMPT_DISABLED": "1"]))
        if result.succeeded {
            let lines = result.stdout.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let url = lines.last else { throw PullRequestError.noURL }
            return url
        }
        guard result.stderr.contains("already exists") else {
            throw PullRequestError.failed(result.stderr.isEmpty ? "exit status \(result.exitCode)" : result.stderr)
        }
        if let url = Self.firstURL(in: result.stderr) { return url }
        let view = try await runner.run(Command(
            executable: "gh", arguments: ["pr", "view", head, "--json", "url", "-q", ".url"],
            workingDirectory: repo, environment: ["GH_PROMPT_DISABLED": "1"]))
        let url = view.stdout.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
        guard view.succeeded, let url, !url.isEmpty else { throw PullRequestError.failed(result.stderr) }
        return url
    }

    private static func firstURL(in text: String) -> String? {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
            .first { $0.hasPrefix("https://") || $0.hasPrefix("http://") }
    }
}
