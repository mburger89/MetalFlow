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
        for c in ["init-flow", "launch", "list", "show", "answer", "follow-up", "resume", "pick", "discard", "branch"] {
            #expect(usageText.contains("  \(c) "))
        }
    }

    @Test func usageSaysAFollowedUpRunIsStoppedNotCancelled() {
        #expect(usageText.contains("A run that has had a follow-up is\nstopped instead of cancelled"))
    }

    @Test func followUpIsKnownAndNeedsAMessage() throws {
        #expect(knownCommands.contains("follow-up"))
        #expect(commandLineProblem(["follow-up"]) == nil)
        #expect(usageText.contains("  follow-up <id> <nodeKey> [--] <message...>"))
        // Too few words is a usage error (exit 64); everything after `--` is the message, flags included.
        let few = try parseArguments(["id", "implement@a"])
        let error = #expect(throws: UsageError.self) { try requirePositionals(few, min: 3, name: "follow-up") }
        #expect(error.map { failureReport($0).code } == 64)
        let full = try parseArguments(["id", "implement@a", "--", "--allow", "more", "tests"])
        try requirePositionals(full, min: 3, name: "follow-up")
        #expect(full.positionals.dropFirst(2).joined(separator: " ") == "--allow more tests")
    }

    @Test func followUpRejectsOptions() throws {
        for options in [["--allow", "Edit"], ["--repo", "/r"], ["--flow", "f"], ["--set", "a=b"], ["--force"]] {
            let a = try parseArguments(["id", "implement@a"] + options + ["more"])
            #expect(usageMessage { try rejectOptions(a, for: "follow-up") } == "follow-up takes no options (use -- before a message that starts with --)")
        }
        let plain = try parseArguments(["id", "implement@a", "--", "--allow", "x"])
        try rejectOptions(plain, for: "follow-up")
    }

    @Test func parsesForceFlag() throws {
        #expect(try parseArguments(["--force", "--repo", "/r"]).force)
        #expect(try parseArguments([]).force == false)
        #expect(usageText.contains("init-flow [--repo DIR] [--force]"))
    }

    @Test func initFlowRefusesExistingFileWithoutForce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("initflow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("fix-issue.flow")
        try checkInitFlowTarget(file, force: false)
        try Data("old".utf8).write(to: file)
        do {
            try checkInitFlowTarget(file, force: false)
            Issue.record("expected a refusal")
        } catch let e as CommandFailure {
            #expect(e.message == "\(file.path) already exists; not overwriting (pass --force to replace it)")
        }
        try checkInitFlowTarget(file, force: true)
    }
}
