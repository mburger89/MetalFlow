import MetalFlowCore
import Testing
@testable import MetalFlowKit

@Suite struct NodeStateStyleTests {
    private func expect(_ state: NodeState, _ label: String, _ tone: Tone, _ symbol: String, detail: String? = nil,
                        sourceLocation: SourceLocation = #_sourceLocation) {
        let style = NodeStateStyle(state)
        #expect(style.label == label, sourceLocation: sourceLocation)
        #expect(style.tone == tone, sourceLocation: sourceLocation)
        #expect(style.symbol == symbol, sourceLocation: sourceLocation)
        #expect(style.detail == detail, sourceLocation: sourceLocation)
    }

    @Test func waiting() { expect(.waiting, "Waiting", .muted, "·") }
    @Test func running() { expect(.running, "Running", .accent, "●") }
    @Test func succeeded() { expect(.succeeded, "Done", .ok, "✓") }
    @Test func failed() { expect(.failed("boom"), "Failed", .bad, "✕", detail: "boom") }
    @Test func interrupted() { expect(.interrupted, "Interrupted", .warn, "·") }
    @Test func cancelled() { expect(.cancelled, "Cancelled", .muted, "·") }

    @Test func needsYouQuestion() { expect(.needsYou(.question("why?")), "Needs you", .warn, "?", detail: "question") }
    @Test func needsYouDeniedTools() { expect(.needsYou(.deniedTools(["Bash"])), "Needs you", .warn, "?", detail: "approval") }
    @Test func needsYouPickWinner() {
        expect(.needsYou(.pickWinner(recommended: "b", allGatesFailed: false)), "Needs you", .warn, "?", detail: "pick a winner")
    }
    @Test func needsYouEveryGateFailed() {
        expect(.needsYou(.pickWinner(recommended: nil, allGatesFailed: true)), "Needs you", .bad, "?", detail: "gate failed")
    }

    @Test func textJoinsLabelAndDetail() {
        #expect(NodeStateStyle(.waiting).text == "Waiting")
        #expect(NodeStateStyle(.failed("boom")).text == "Failed: boom")
        #expect(NodeStateStyle(.needsYou(.question("q"))).text == "Needs you: question")
    }

    @Test func runStatusWordsShareTheNodeLabels() {
        #expect(NodeStateStyle.needsYouLabel == "Needs you")
        #expect(NodeStateStyle(.running).label == "Running")
    }

    @Test func pillStatesMapToTones() {
        #expect(StepPill.State.done.tone == .ok)
        #expect(StepPill.State.run.tone == .accent)
        #expect(StepPill.State.wait.tone == .muted)
        #expect(StepPill.State.fail.tone == .bad)
    }
}
