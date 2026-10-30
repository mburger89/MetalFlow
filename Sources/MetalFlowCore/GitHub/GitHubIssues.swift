import Foundation

/// A GitHub issue used as input to a flow run.
public struct Issue: Codable, Sendable, Equatable {
    /// Issue number within its repository.
    public var number: Int
    /// Issue title.
    public var title: String
    /// Issue body; empty when GitHub reports none.
    public var body: String
    /// Web URL of the issue.
    public var url: String
    /// Label names.
    public var labels: [String]

    /// Creates an issue.
    public init(number: Int, title: String, body: String, url: String, labels: [String]) {
        self.number = number
        self.title = title
        self.body = body
        self.url = url
        self.labels = labels
    }

    /// The issue rendered for use in a prompt: `#<n> <title>`, a blank line, then the body.
    public var promptText: String { "#\(number) \(title)\n\n\(body)" }
}

/// Failures from fetching a GitHub issue.
public enum GitHubError: Error, Equatable {
    /// The reference was neither an issue number (`42`, `#42`) nor an http(s) URL.
    case invalidReference(String)
}

extension GitHubError: LocalizedError {
    /// A readable message.
    public var errorDescription: String? {
        switch self {
        case .invalidReference(let ref):
            return "'\(ref)' is not an issue number (42, #42) or an http(s) issue URL"
        }
    }
}

/// Fetches issues through the `gh` CLI.
public struct GitHubIssues: Sendable {
    private let runner: any CommandRunner

    /// Creates a fetcher that runs `gh` through `runner`.
    public init(runner: any CommandRunner) {
        self.runner = runner
    }

    private struct Payload: Decodable {
        struct Label: Decodable { var name: String }
        var number: Int
        var title: String
        var body: String?
        var url: String
        var labels: [Label]
    }

    /// Fetches the issue named by `ref` (`"42"`, `"#42"` or an issue URL) using `gh` run in `repo`.
    public func fetch(_ ref: String, repo: URL) async throws -> Issue {
        let argument = try Self.normalize(ref)
        let result = try await runner.check(Command(
            executable: "gh",
            arguments: ["issue", "view", argument, "--json", "number,title,body,url,labels"],
            workingDirectory: repo))
        let payload = try JSONDecoder().decode(Payload.self, from: Data(result.stdout.utf8))
        return Issue(number: payload.number, title: payload.title, body: payload.body ?? "",
                     url: payload.url, labels: payload.labels.map(\.name))
    }

    private static func normalize(_ ref: String) throws -> String {
        let trimmed = ref.trimmingCharacters(in: .whitespaces)
        let number = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        if !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) { return number }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https", url.host?.isEmpty == false {
            return trimmed
        }
        throw GitHubError.invalidReference(ref)
    }
}
