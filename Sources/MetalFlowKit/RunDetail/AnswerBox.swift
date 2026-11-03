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
        ReplyField(
            placeholder: "Reply", id: "answer.\(runID.rawValue).\(key)",
            text: Binding(
                get: { model.answerDrafts[draftKey] ?? "" },
                set: { model.answerDrafts[draftKey] = $0 }),
            send: send)
    }

    private func send() {
        let (model, runID, key) = (model, runID, key)
        Task { await model.sendAnswer(run: runID, node: key) }
    }
}
