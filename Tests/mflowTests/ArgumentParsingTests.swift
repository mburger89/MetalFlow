import Foundation
import Testing
import MetalFlowCore
@testable import mflow

@Suite struct ArgumentParsingTests {
    /// The message of the `UsageError` a call throws, or nil if it does not.
    private func usageMessage(_ body: () throws -> Void) -> String? {
        do { try body() } catch let e as UsageError { return e.message } catch { return nil }
        return nil
    }

    @Test func parsesFlagsAnywhereAmongPositionals() throws {
        let a = try parseArguments(["7", "--repo", "/r", "--flow", "f.flow", "extra", "--allow", "Bash", "--allow", "Edit"])
        #expect(a.positionals == ["7", "extra"])
        #expect(a.repo == "/r")
        #expect(a.flow == "f.flow")
        #expect(a.allow == ["Bash", "Edit"])
        #expect(a.sets.isEmpty)
    }

    @Test func emptyArgumentsYieldDefaults() throws {
        let a = try parseArguments([])
        #expect(a.positionals.isEmpty && a.repo == nil && a.flow == nil && a.allow.isEmpty && a.sets.isEmpty)
    }

    @Test func repeatedSetKeepsOrderAndSplitsOnFirstEquals() throws {
        let a = try parseArguments(["--set", "issue=7", "--set", "env=a=b", "--set", "note="])
        #expect(a.sets.map(\.0) == ["issue", "env", "note"])
        #expect(a.sets.map(\.1) == ["7", "a=b", ""])
    }

    @Test func lastRepoAndFlowWin() throws {
        let a = try parseArguments(["--repo", "/a", "--repo", "/b", "--flow", "x", "--flow", "y"])
        #expect(a.repo == "/b" && a.flow == "y")
    }

    @Test func badSetIsAUsageError() {
        for bad in ["noequals", "=v", ""] {
            let m = usageMessage { _ = try parseArguments(["--set", bad]) }
            #expect(m == "expected --set name=value, got '\(bad)'")
        }
    }

    @Test func flagWithoutValueIsAUsageError() {
        for flag in ["--repo", "--flow", "--allow", "--set"] {
            #expect(usageMessage { _ = try parseArguments(["x", flag]) } == "\(flag) needs a value")
        }
    }

    @Test func flagTakesNextTokenEvenIfItLooksLikeAFlag() throws {
        let a = try parseArguments(["--repo", "--flow"])
        #expect(a.repo == "--flow" && a.flow == nil)
    }

    @Test func unknownOptionIsAUsageError() {
        #expect(usageMessage { _ = try parseArguments(["--bogus"]) } == "unknown option --bogus")
        #expect(usageMessage { _ = try parseArguments(["ok", "--Repo", "x"]) } == "unknown option --Repo")
    }

    @Test func doubleDashEndsOptions() throws {
        let a = try parseArguments(["id", "node", "--", "--repo", "--set", "reply"])
        #expect(a.positionals == ["id", "node", "--repo", "--set", "reply"])
        #expect(a.repo == nil && a.sets.isEmpty)
        #expect(try parseArguments(["--"]).positionals.isEmpty)
    }

    @Test func singleDashAndEmptyTokensArePositionals() throws {
        #expect(try parseArguments(["-x", "", "-"]).positionals == ["-x", "", "-"])
    }

    @Test func requirePositionalsEnforcesBounds() throws {
        var a = Arguments()
        #expect(throws: Never.self) { try requirePositionals(a, min: 0, max: 0, name: "list") }
        #expect(usageMessage { try requirePositionals(a, min: 1, max: 1, name: "show") } == "wrong arguments for show")
        a.positionals = ["a", "b"]
        #expect(usageMessage { try requirePositionals(a, min: 0, max: 1, name: "launch") } == "wrong arguments for launch")
        #expect(throws: Never.self) { try requirePositionals(a, min: 2, max: 2, name: "pick") }
        #expect(throws: Never.self) { try requirePositionals(a, min: 1, name: "answer") }
        #expect(usageMessage { try requirePositionals(a, min: 3, name: "answer") } == "wrong arguments for answer")
    }

    @Test func parseRunIDValidatesAndUppercases() throws {
        let u = UUID().uuidString
        #expect(try parseRunID(u.lowercased()).rawValue == u)
        for bad in ["", "7", "not-a-uuid"] {
            do { _ = try parseRunID(bad); Issue.record("accepted \(bad)") } catch let e as CommandFailure {
                #expect(e.message == "'\(bad)' is not a run id")
            }
        }
    }

    @Test func usageTextListsEveryCommand() {
        for c in ["init-flow", "launch", "list", "show", "answer", "resume", "pick", "discard", "branch"] {
            #expect(usageText.contains("  \(c) "))
        }
    }
}
