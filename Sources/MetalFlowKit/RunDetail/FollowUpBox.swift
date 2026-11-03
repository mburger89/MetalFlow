import Foundation
import MetalUI
import MetalFlowCore

/// A message field and Send button for a follow-up to a finished step, with a line saying what sending does.
/// The text is kept in the model so closing the box and rebuilds keep it.
struct FollowUpBox: Component {
    let model: AppModel
    let runID: RunID
    let key: NodeKey

    var content: some ElementGroup {
        let draftKey = AppModel.draftKey(runID, key)
        let id = "followUp.\(runID.rawValue).\(key)"
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ReplyField(
                placeholder: "Follow up", id: id,
                text: Binding(
                    get: { model.followUpDrafts[draftKey] ?? "" },
                    set: { model.followUpDrafts[draftKey] = $0 }),
                sending: model.followUpSending.contains(draftKey), send: send)
            Text(verbatim: "The steps after this one run again.").font(size: 12).foregroundColor(Palette.muted)
                .accessibilityIdentifier("\(id).hint")
        }
    }

    private func send() {
        let (model, runID, key) = (model, runID, key)
        Task { await model.sendFollowUp(run: runID, node: key) }
    }
}
