import Foundation
import MetalFlowCore
import MetalUI

/// "now", "5m", "3h", "2d".
func ageText(_ seconds: TimeInterval) -> String {
    let s = Int(max(0, seconds))
    if s < 60 { return "now" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h" }
    return "\(s / 86_400)d"
}

/// Runs that are over, newest first, at most 20.
struct FinishedList: Component {
    let model: AppModel
    static let limit = 20

    var content: some ElementGroup {
        let runs = Array(model.finished.prefix(Self.limit))
        if !runs.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("RECENTLY FINISHED").font(size: 11).foregroundColor(Palette.muted)
                    .accessibilityIdentifier("finished")
                    .padding(lengthInsets(top: 0, right: 0, bottom: 6, left: 0))
                ForEach(runs, id: \.id) { run in
                    FinishedRow(model: model, run: run)
                }
            }
        }
    }
}

/// One finished run: title, result and age. Clicking opens it.
struct FinishedRow: Component {
    let model: AppModel
    let run: Run

    var content: some ElementGroup {
        let (result, color) = Self.result(run.status)
        let finishedAt = run.nodes.values.compactMap(\.endedAt).max() ?? run.createdAt
        let id = run.id
        VStack(spacing: 0) {
            HStack(spacing: Spacing.md) {
                Text(verbatim: run.title).font(size: 13).foregroundColor(Palette.text)
                    .accessibilityIdentifier("finished.\(id.rawValue)")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: result).font(size: 12).foregroundColor(color)
                    .accessibilityIdentifier("finished.\(id.rawValue).result")
                Text(verbatim: ageText(model.now.timeIntervalSince(finishedAt))).font(size: 12).foregroundColor(Palette.muted)
                    .accessibilityIdentifier("finished.\(id.rawValue).age")
                    .frame(width: Pixels(56), alignment: .trailing)
            }
            .padding(insets(top: 8, right: 0, bottom: 8, left: 0))
            .onTapGesture { model.open(run: id) }
            Divider()
        }
    }

    static func result(_ status: RunStatus) -> (String, Color) {
        switch status {
        case .merged(let lane): ("Merged \(lane.uppercased())", Palette.ok)
        case .discarded: ("Discarded", Palette.muted)
        case .completed: ("Completed", Palette.ok)
        case .failed: ("Failed", Palette.bad)
        case .cancelled: ("Cancelled", Palette.muted)
        case .running, .needsYou: ("", Palette.muted)
        }
    }
}
