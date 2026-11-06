import Testing
@testable import MetalFlowCore

@Suite("ToolPermissions")
struct ToolPermissionsTests {
    @Test func plainToolsAreAllowedByName() {
        let p = ToolPermissions(allowedTools: ["Read", "Grep"])
        #expect(p.allows(tool: "Read"))
        #expect(p.allows(tool: "Grep"))
        #expect(!p.allows(tool: "Write"))
        #expect(!p.allows(tool: "Bash"))
    }

    @Test func bashPrefixMatchesLeadingWords() {
        let p = ToolPermissions(allowedTools: ["Bash(git diff:*)", "Bash(swift test:*)"])
        #expect(p.allowsBash(command: "git diff"))
        #expect(p.allowsBash(command: "git diff --stat"))
        #expect(p.allowsBash(command: "swift test --no-parallel"))
        #expect(!p.allowsBash(command: "git push"))
        #expect(!p.allowsBash(command: "swift build"))
        #expect(!p.allowsBash(command: "git"))
    }

    @Test func prefixIsWholeWordsOnly() {
        let p = ToolPermissions(allowedTools: ["Bash(git diff:*)"])
        #expect(!p.allowsBash(command: "git difftool"))
        #expect(!p.allowsBash(command: "git diffx --stat"))
    }

    @Test func bareBashAllowsAnyCommandWithoutOperators() {
        let p = ToolPermissions(allowedTools: ["Bash"])
        #expect(p.allowsBash(command: "ls -la"))
        #expect(!p.allowsBash(command: "ls; rm x"))
        #expect(!p.allowsBash(command: "ls | wc"))
    }

    @Test func operatorsAreRefusedEvenWithAMatchingPrefix() {
        let p = ToolPermissions(allowedTools: ["Bash(git diff:*)"])
        #expect(!p.allowsBash(command: "git diff && git push"))
        #expect(!p.allowsBash(command: "git diff > out"))
    }

    @Test func noBashEntryDeniesBash() {
        let p = ToolPermissions(allowedTools: ["Read"])
        #expect(!p.allowsBash(command: "ls"))
    }
}
