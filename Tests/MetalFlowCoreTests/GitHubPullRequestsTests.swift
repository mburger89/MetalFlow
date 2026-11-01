import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct GitHubPullRequestsTests {
    let repo = URL(fileURLWithPath: "/work/repo")

    private func make(_ result: CommandResult) -> (FakeCommandRunner, GitHubPullRequests) {
        let fake = FakeCommandRunner()
        fake.stub("gh", ["pr"], result: result)
        return (fake, GitHubPullRequests(runner: fake))
    }

    @Test func theURLIsTheLastNonEmptyLineOfStdout() async throws {
        let (fake, prs) = make(CommandResult(
            exitCode: 0, stdout: "Creating pull request for x into main in a/b\n\nhttps://github.com/a/b/pull/3\n\n", stderr: ""))
        let url = try await prs.create(repo: repo, base: "main", head: "x", title: "T", body: "B", draft: false)
        #expect(url == "https://github.com/a/b/pull/3")
        #expect(fake.calls.count == 1)
    }

    @Test func argumentsAreSeparateEntriesInTheRepo() async throws {
        let (fake, prs) = make(CommandResult(exitCode: 0, stdout: "https://x/pull/1\n", stderr: ""))
        let awkward = "Fix \"quotes\"; rm -rf / $(whoami)"
        _ = try await prs.create(repo: repo, base: "main", head: "flow/7-x--b", title: awkward, body: "Closes #7\n\nbody", draft: true)
        let call = try #require(fake.calls.first)
        #expect(call.executable == "gh")
        #expect(call.arguments == ["pr", "create", "--base", "main", "--head", "flow/7-x--b", "--title", awkward,
                                   "--body", "Closes #7\n\nbody", "--draft"])
        #expect(call.workingDirectory == repo)
    }

    @Test func aFailureCarriesGhsStderr() async throws {
        let (_, prs) = make(CommandResult(exitCode: 1, stdout: "", stderr: "gh: To use GitHub CLI, run: gh auth login\n"))
        do {
            _ = try await prs.create(repo: repo, base: "main", head: "x", title: "T", body: "B", draft: true)
            Issue.record("should have thrown")
        } catch let error as PullRequestError {
            #expect(error == .failed("gh: To use GitHub CLI, run: gh auth login\n"))
            #expect(error.localizedDescription.contains("gh auth login"))
        }
    }

    @Test func aSuccessWithoutAnURLThrows() async throws {
        let (_, prs) = make(CommandResult(exitCode: 0, stdout: "\n \n", stderr: ""))
        await #expect(throws: PullRequestError.noURL) {
            _ = try await prs.create(repo: repo, base: "main", head: "x", title: "T", body: "B", draft: true)
        }
    }

    @Test func aMissingGhIsReported() async throws {
        let prs = GitHubPullRequests(runner: FakeCommandRunner())
        await #expect(throws: CommandError.executableNotFound("gh")) {
            _ = try await prs.create(repo: repo, base: "main", head: "x", title: "T", body: "B", draft: true)
        }
    }

    @Test func pushNeverForces() async throws {
        let fake = FakeCommandRunner()
        fake.stub("git", ["-C"], result: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        try await Git(runner: fake).push(repo: repo, branch: "flow/7-x--b")
        let call = try #require(fake.calls.first)
        #expect(call.arguments == ["-C", "/work/repo", "push", "-u", "origin", "flow/7-x--b"])
        #expect(!call.arguments.contains { $0.hasPrefix("--force") || $0 == "-f" || $0.hasPrefix("+") })
        #expect(call.environment["GIT_TERMINAL_PROMPT"] == "0")
    }

    @Test func aFailedPushThrowsWithStderr() async throws {
        let fake = FakeCommandRunner()
        fake.stub("git", ["-C"], result: CommandResult(exitCode: 128, stdout: "", stderr: "fatal: unable to access\n"))
        await #expect(throws: GitError.pushFailed(stderr: "fatal: unable to access\n")) {
            try await Git(runner: fake).push(repo: repo, branch: "b")
        }
        #expect(GitError.pushFailed(stderr: "fatal: unable to access\n").errorDescription == "git push failed: fatal: unable to access")
    }
}
