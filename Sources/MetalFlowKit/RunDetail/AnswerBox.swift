import Foundation
import MetalUI
import MetalFlowCore

/// A reply field and Send button for a node's question. The text is kept in the model so it survives rebuilds.
struct AnswerBox: Component {
    let model: AppModel
    let runID: RunID
    let key: NodeKey

    var content: some ElementGroup {
        let draftKey = AppModel.draftKey(runID, key)
        let id = "answer.\(runID.rawValue).\(key)"
        HStack(spacing: Spacing.sm) {
            TextField("Reply", text: Binding(
                get: { model.answerDrafts[draftKey] ?? "" },
                set: { model.answerDrafts[draftKey] = $0 }))
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("\(id).field")
            Button("Send") { send() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(id).send")
                .disabled(AppModel.trimmed(model.answerDrafts[draftKey] ?? "").isEmpty)
        }
    }

    private func send() {
        let (model, runID, key) = (model, runID, key)
        Task { await model.sendAnswer(run: runID, node: key) }
    }
}
