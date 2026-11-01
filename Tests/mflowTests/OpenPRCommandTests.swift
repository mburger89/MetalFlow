import Foundation
import Testing
import MetalFlowCore
@testable import mflow

@Suite struct OpenPRCommandTests {
    private let url = "https://github.com/acme/widgets/pull/12"

    private func run(_ status: RunStatus) -> Run {
        Run(id: RunID(rawValue: "ID1"), flow: BuiltinFlows.fixGitHubIssue, title: "Fix #7", repo: URL(fileURLWithPath: "/repo"),
            baseBranch: "main", branch: "mflow/7", worktree: URL(fileURLWithPath: "/wt"), status: status)
    }

    @Test func statusTextNamesTheLaneAndTheURL() {
        #expect(mflow.statusText(.prOpened("b", url: url)) == "PR opened (b): \(url)")
    }

    @Test func showAndListLinesCarryTheStatus() {
        #expect(runSummary(run(.prOpened("b", url: url))).first == "ID1  PR opened (b): \(url)  Fix #7")
    }

    @Test func theURLIsPrintedOnlyForARunThatOpenedOne() {
        #expect(pullRequestLine(run(.prOpened("b", url: url))) == url)
        #expect(pullRequestLine(run(.failed("gh: not logged in"))) == nil)
        #expect(pullRequestLine(run(.running)) == nil)
        #expect(pullRequestLine(nil) == nil)
    }

    @Test func aHandedOffPickIsNotReportedAsAMerge() {
        #expect(mergeResultText(.handedToPullRequest) == "not merged: opening a pull request instead")
    }

    @Test func usageDescribesThePullRequestBehaviour() {
        #expect(usageText.contains("Open PR"))
        #expect(usageText.contains("print the pull request's URL"))
        #expect(usageText.contains("pull request opened"))
        #expect(usageText.contains("pull request not opened"))
        #expect(usageText.contains("  pick <id> <lane> "))
    }

    @Test func thereIsNoRetryCommandYet() {
        #expect(commandLineProblem(["retry", "x"])?.hasPrefix("mflow: unknown command 'retry'") == true)
    }
}
