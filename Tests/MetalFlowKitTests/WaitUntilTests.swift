import Testing

@MainActor
@Suite struct WaitUntilTests {
    @Test func recordsAnIssueAtTheDeadline() async {
        await withKnownIssue {
            let held = await waitUntil("never", timeout: .milliseconds(10)) { false }
            #expect(!held)
        }
    }
}
