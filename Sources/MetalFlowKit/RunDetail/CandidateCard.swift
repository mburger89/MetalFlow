import MetalFlowCore
import MetalUI

/// One candidate lane: model, gate result, size, branch, the judge's tag and the pick / diff / branch actions.
struct CandidateCard: Component {
    let model: AppModel
    let run: Run
    let lane: Lane

    var content: some ElementGroup {
        let runID = run.id
        let laneID = lane.id
        let id = "cand.\(laneID)"
        let recommended = run.recommendation == laneID
        let key = AppModel.laneKey(runID, laneID)
        let outcome = model.pickOutcomes[runID]?[laneID]
        let canPick = model.canPick(run) && model.pickingRun == nil
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Text(verbatim: "Candidate \(laneID.uppercased())").font(size: 14).foregroundColor(Palette.text)
                    .accessibilityIdentifier("\(id).title")
                Spacer()
                if recommended {
                    HStack(spacing: 0) {
                        Text(verbatim: "JUDGE RECOMMENDS").font(size: 10).foregroundColor(Palette.accent)
                            .accessibilityIdentifier("\(id).recommended")
                    }
                    .padding(insets(top: 2, right: 6, bottom: 2, left: 6))
                    .background(Palette.accent.opacity(0.16))
                    .cornerRadius(4)
                }
            }
            Text(verbatim: lane.model).font(size: 12).foregroundColor(Palette.muted)
                .accessibilityIdentifier("\(id).model")
            Text(verbatim: gateText).font(size: 13).foregroundColor(gateColor)
                .accessibilityIdentifier("\(id).gate")
            HStack(spacing: Spacing.sm) {
                Text(verbatim: "+\(lane.added)").font(Theme.mono(12)).foregroundColor(Palette.ok)
                    .accessibilityIdentifier("\(id).added")
                Text(verbatim: "−\(lane.removed)").font(Theme.mono(12)).foregroundColor(Palette.bad)
                    .accessibilityIdentifier("\(id).removed")
            }
            Chip(text: lane.branch, mono: true)
            HStack(spacing: Spacing.sm) {
                pickButton(canPick: canPick, recommended: recommended, id: id)
                Button(model.openDiff == DiffKey(run: runID, lane: laneID) ? "Hide diff" : "View diff") {
                    Task { await model.toggleDiff(runID, lane: laneID) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(id).diff")
            }
            Button("Branch from here") { model.toggleBranch(runID, laneID) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(id).branch")
            if model.isBranchOpen(runID, laneID) {
                let name = model.branchDrafts[key] ?? ""
                HStack(spacing: Spacing.sm) {
                    TextField("Branch name", text: Binding(
                        get: { model.branchDrafts[key] ?? "" },
                        set: { model.branchDrafts[key] = $0 }))
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("\(id).branch.name")
                    Button("OK") { Task { await model.submitBranch(runID, lane: laneID) } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("\(id).branch.ok")
                        .disabled(AppModel.trimmed(name).isEmpty)
                }
            }
            if let outcome {
                Text(verbatim: outcome.message).font(size: 12)
                    .foregroundColor(outcome == .merged ? Palette.ok : Palette.warn)
                    .accessibilityIdentifier("\(id).result")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Edges(all: Spacing.md))
        .background(Palette.panel)
        .cornerRadius(10)
        .border(recommended ? Palette.accent : Palette.line, width: 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
    }

    @ElementBuilder
    private func pickButton(canPick: Bool, recommended: Bool, id: String) -> some ElementGroup {
        let runID = run.id
        let laneID = lane.id
        if recommended {
            Button("Pick & merge") { Task { await model.pick(runID, lane: laneID) } }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("\(id).pick")
                .disabled(!canPick)
        } else {
            Button("Pick & merge") { Task { await model.pick(runID, lane: laneID) } }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(id).pick")
                .disabled(!canPick)
        }
    }

    private var gateText: String {
        switch lane.gatePassed {
        case true?: "Tests passed"
        case false?: "Tests failed"
        case nil: "No gate"
        }
    }

    private var gateColor: Color {
        switch lane.gatePassed {
        case true?: Palette.ok
        case false?: Palette.bad
        case nil: Palette.muted
        }
    }
}
