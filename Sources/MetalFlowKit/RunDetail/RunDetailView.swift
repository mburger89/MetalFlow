import Foundation
import MetalFlowCore
import MetalUI

/// One run in detail: its steps, what needs the user, the judge's verdict, and the candidate lanes to compare.
public struct RunDetailView: Component {
    let model: AppModel
    let runID: RunID

    /// Creates the detail of a run.
    public init(model: AppModel, run: RunID) {
        self.model = model
        self.runID = run
    }

    public var content: some ElementGroup {
        if let run = model.runs[runID] {
            DetailBody(model: model, run: run)
        } else {
            Text(verbatim: "Run not found").foregroundColor(Palette.muted)
                .accessibilityIdentifier("detail.missing")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DetailBody: Component {
    let model: AppModel
    let run: Run

    var content: some ElementGroup {
        let runID = run.id
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                HStack(spacing: Spacing.md) {
                    Button("← Back") { model.selectedRun = nil }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("detail.back")
                    Text(verbatim: run.title).font(size: 16).foregroundColor(Palette.text)
                        .accessibilityIdentifier("detail.title")
                    Text(verbatim: model.statusText(run)).font(size: 12).foregroundColor(Palette.muted)
                        .accessibilityIdentifier("detail.status")
                    Spacer()
                    if run.status == .running {
                        // A running run cannot be discarded; cancel it first. One another process drives is not ours.
                        if !model.runningElsewhere.contains(runID) {
                            Button("Cancel") { Task { await model.cancel(runID) } }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("detail.cancel")
                        }
                    } else {
                        Button("Discard") { model.confirmingDiscard = runID }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("detail.discard")
                    }
                }
                StepsSection(model: model, run: run)
                if let judge = judgeOutput {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(verbatim: "JUDGE").font(size: 11).foregroundColor(Palette.muted)
                        Text(verbatim: judge).font(size: 13).foregroundColor(Palette.text)
                            .accessibilityIdentifier("detail.judge")
                    }
                }
                if allGatesFailed {
                    Text(verbatim: "No candidate passed the tests").font(size: 13).foregroundColor(Palette.bad)
                        .accessibilityIdentifier("detail.allGatesFailed")
                }
                if !run.lanes.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Pixels(280)))], spacing: Spacing.md) {
                        ForEach(run.lanes, id: \.id) { lane in
                            CandidateCard(model: model, run: run, lane: lane)
                        }
                    }
                }
                OpenDiffSection(model: model, run: runID)
            }
            .padding(insets(top: 18, right: 20, bottom: 20, left: 20))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
        .overlay(alignment: .topLeading) {
            Spacer().frame(width: 0, height: 0).accessibilityIdentifier("detail")
        }
        .alert("Discard this run?", isPresented: Binding(
            get: { model.confirmingDiscard == runID },
            set: { if !$0, model.confirmingDiscard == runID { model.confirmingDiscard = nil } })) {
            Button("Discard", role: .destructive) { Task { await model.discard(runID) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The run's worktree and branches are thrown away.")
        }
    }

    private var allGatesFailed: Bool {
        run.nodes.values.contains { if case .needsYou(.pickWinner(_, true)) = $0.state { true } else { false } }
    }

    private var judgeOutput: String? {
        for node in run.flow.nodes {
            guard case .judge = node.kind else { continue }
            if let output = run.nodes[NodeKey(node: node.id)]?.output, !output.isEmpty { return output }
        }
        return nil
    }
}

/// The run's nodes with their states, and the actions a waiting node offers.
struct StepsSection: Component {
    let model: AppModel
    let run: Run

    var content: some ElementGroup {
        let rows = Self.rows(run)
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(verbatim: "STEPS").font(size: 11).foregroundColor(Palette.muted)
            ForEach(rows, id: \.key) { row in
                StepRow(model: model, run: run, row: row)
            }
        }
    }

    struct Row {
        var key: NodeKey
        var title: String
        var state: NodeState
    }

    /// One row per execution, in plan order. A node with no execution yet is one waiting row.
    static func rows(_ run: Run) -> [Row] {
        let order = (try? run.flow.validate().order) ?? run.flow.nodes.map(\.id)
        var rows: [Row] = []
        for id in order {
            guard let node = run.flow.node(id) else { continue }
            let keys = run.nodes.keys.filter { $0.node == id }.sorted { ($0.lane ?? "") < ($1.lane ?? "") }
            if keys.isEmpty {
                rows.append(Row(key: NodeKey(node: id), title: node.title, state: .waiting))
            }
            for key in keys {
                guard let state = run.nodes[key]?.state else { continue }
                rows.append(Row(key: key, title: node.title, state: state))
            }
        }
        return rows
    }
}

struct StepRow: Component {
    let model: AppModel
    let run: Run
    let row: StepsSection.Row

    var content: some ElementGroup {
        let id = "detail.node.\(row.key)"
        let (label, color) = Self.describe(row.state)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Spacing.sm) {
                Text(verbatim: row.key.lane.map { "\(row.title) (\($0.uppercased()))" } ?? row.title)
                    .font(size: 13).foregroundColor(Palette.text)
                    .accessibilityIdentifier(id)
                Text(verbatim: label).font(size: 12).foregroundColor(color)
                    .accessibilityIdentifier("\(id).state")
            }
            action
        }
    }

    @ElementBuilder
    private var action: some ElementGroup {
        let id = "detail.node.\(row.key)"
        let runID = run.id
        let key = row.key
        if case .needsYou(.question(let question)) = row.state {
            Text(verbatim: question).font(size: 13).foregroundColor(Palette.body)
            AnswerBox(model: model, runID: runID, key: key)
        }
        if case .needsYou(.deniedTools(let tools)) = row.state {
            Button("Allow & continue") {
                Task { await model.allowAndContinue(run: runID, node: key, tools: tools) }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("\(id).allow")
        }
        if row.state == .interrupted {
            Button("Resume") { Task { await model.resume(runID) } }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(id).resume")
        }
        if case .failed = row.state {
            Button("Retry") { Task { await model.retry(runID, node: key) } }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(id).retry")
        }
    }

    static func describe(_ state: NodeState) -> (String, Color) {
        switch state {
        case .waiting: ("Waiting", Palette.muted)
        case .running: ("Running", Palette.accent)
        case .succeeded: ("Done", Palette.ok)
        case .failed(let message): ("Failed: \(message)", Palette.bad)
        case .needsYou(.question): ("Has a question", Palette.warn)
        case .needsYou(.deniedTools): ("Needs approval", Palette.warn)
        case .needsYou(.pickWinner): ("Pick a winner", Palette.warn)
        case .interrupted: ("Interrupted", Palette.warn)
        case .cancelled: ("Cancelled", Palette.muted)
        }
    }
}
