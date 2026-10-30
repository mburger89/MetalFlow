import Foundation
import Testing
@testable import MetalFlowCore

struct GitHubIssuesTests {
    let repo = URL(fileURLWithPath: "/tmp/repo")

    private func stubbed(_ json: String) -> (FakeCommandRunner, GitHubIssues) {
        let fake = FakeCommandRunner()
        fake.stub("gh", ["issue", "view"], result: CommandResult(exitCode: 0, stdout: json, stderr: ""))
        return (fake, GitHubIssues(runner: fake))
    }

    @Test func fetchParsesJSON() async throws {
        let (fake, gh) = stubbed(#"{"number":42,"title":"Crash","body":"Boom","url":"https://github.com/o/r/issues/42","labels":[{"name":"bug"},{"name":"ui"}]}"#)
        let issue = try await gh.fetch("42", repo: repo)
        #expect(issue == Issue(number: 42, title: "Crash", body: "Boom", url: "https://github.com/o/r/issues/42", labels: ["bug", "ui"]))
        #expect(issue.promptText == "#42 Crash\n\nBoom")
        #expect(fake.calls == [Command(executable: "gh", arguments: ["issue", "view", "42", "--json", "number,title,body,url,labels"], workingDirectory: repo)])
    }

    @Test func nullBodyDecodesAsEmpty() async throws {
        let (_, gh) = stubbed(#"{"number":1,"title":"T","body":null,"url":"u","labels":[]}"#)
        #expect(try await gh.fetch("1", repo: repo).body == "")
    }

    @Test func hashPrefixIsStripped() async throws {
        let (fake, gh) = stubbed(#"{"number":42,"title":"T","body":"","url":"u","labels":[]}"#)
        _ = try await gh.fetch("#42", repo: repo)
        #expect(fake.calls.first?.arguments[2] == "42")
    }

    @Test func urlPassesThroughUnchanged() async throws {
        let (fake, gh) = stubbed(#"{"number":42,"title":"T","body":"","url":"u","labels":[]}"#)
        _ = try await gh.fetch("https://github.com/o/r/issues/42", repo: repo)
        #expect(fake.calls.first?.arguments[2] == "https://github.com/o/r/issues/42")
    }

    @Test func invalidReferenceThrows() async throws {
        let (fake, gh) = stubbed("{}")
        for bad in ["", "abc", "--web", "#", "#x1", "ftp://x/1"] {
            await #expect(throws: GitHubError.invalidReference(bad)) {
                _ = try await gh.fetch(bad, repo: repo)
            }
        }
        #expect(fake.calls.isEmpty)
    }

    @Test func ghFailureSurfacesStderr() async throws {
        let fake = FakeCommandRunner()
        fake.stub("gh", ["issue", "view"], result: CommandResult(exitCode: 1, stdout: "", stderr: "could not resolve"))
        let gh = GitHubIssues(runner: fake)
        do {
            _ = try await gh.fetch("7", repo: repo)
            failNoThrow()
        } catch let CommandError.failed(_, exitCode, stderr) {
            #expect(exitCode == 1)
            #expect(stderr.contains("could not resolve"))
        }
    }
}

private func failNoThrow() { #expect(Bool(false), "expected throw") }
