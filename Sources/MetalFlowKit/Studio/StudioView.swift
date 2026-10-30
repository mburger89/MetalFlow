import MetalFlowCore
import MetalUI

/// The Flow Studio: toolbar, node palette, canvas with an optional run overlay, and inspector.
public struct StudioView: Component {
    let model: AppModel

    /// Creates the Studio over a model.
    public init(model: AppModel) { self.model = model }

    public var content: some ElementGroup {
        VStack(spacing: 0) {
            if let draft = model.draft {
                StudioBody(model: model, draft: draft)
            } else {
                Text(verbatim: "Add a repo on the dashboard to open a flow.").foregroundColor(Palette.muted)
                    .accessibilityIdentifier("studio.empty")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
        .overlay(alignment: .topLeading) {
            // A container's identifier would replace those inside it, so the marker is a zero-size element.
            Spacer().frame(width: 0, height: 0).accessibilityIdentifier("studio")
        }
    }
}

struct StudioBody: Component {
    let model: AppModel
    let draft: FlowDraft

    var content: some ElementGroup {
        VStack(spacing: 0) {
            StudioToolbar(model: model, draft: draft)
            Divider()
            HStack(spacing: 0) {
                PaletteView()
                Divider()
                VStack(spacing: 0) {
                    CanvasView(model: model, draft: draft)
                    if let run = model.studioShownRun, !run.lanes.isEmpty {
                        Divider()
                        CandidatesStrip(model: model, run: run)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                InspectorView(draft: draft)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Flow name, file, run picker, Save and Launch with issue.
struct StudioToolbar: Component {
    let model: AppModel
    let draft: FlowDraft

    var content: some ElementGroup {
        let valid = model.draftIsValid
        HStack(spacing: Spacing.md) {
            Text(verbatim: draft.flow.name).font(size: 14).foregroundColor(Palette.text)
                .accessibilityIdentifier("studio.name")
            Text(verbatim: Self.fileText(draft)).font(size: 12).foregroundColor(Palette.muted)
                .accessibilityIdentifier("studio.file")
            if case .failure(let error) = draft.validation {
                Text(verbatim: error.localizedDescription).font(size: 12).foregroundColor(Palette.bad)
                    .accessibilityIdentifier("studio.error")
                    .lineLimit(1)
            }
            Spacer()
            Picker("Show run", selection: Binding(
                get: { model.studioShownRun?.id.rawValue ?? "" },
                set: { value in model.studioRun = model.studioRuns.first { $0.id.rawValue == value }?.id })) {
                Text("Definition only").tag("")
                ForEach(model.studioRuns, id: \.id) { run in
                    Text(verbatim: "Showing \(run.title)").tag(run.id.rawValue)
                }
            }
            .frame(width: Pixels(260))
            .accessibilityIdentifier("studio.runPicker")
            Button("Save") { Task { await model.saveDraft() } }
                .buttonStyle(.bordered)
                .keyboardShortcut("s")
                .accessibilityIdentifier("studio.save")
                .disabled(!valid)
            TextField("Issue #68 or URL", text: Binding(get: { model.studioIssue }, set: { model.studioIssue = $0 }))
                .frame(width: Pixels(180))
                .accessibilityIdentifier("studio.issue")
            Button("▶ Launch with issue…") { Task { await model.launchFromStudio() } }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("studio.launch")
                .disabled(!valid || model.isLaunching || AppModel.trimmed(model.studioIssue).isEmpty)
        }
        .padding(insets(top: 8, right: 14, bottom: 8, left: 14))
        .background(Palette.chrome)
    }

    static func fileText(_ draft: FlowDraft) -> String {
        let file = draft.url.map { $0.lastPathComponent } ?? "Unsaved"
        return draft.isDirty ? "\(file) · edited" : file
    }
}

/// The run's candidate cards under the canvas.
struct CandidatesStrip: Component {
    let model: AppModel
    let run: Run

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                Text("Candidates").font(size: 13).foregroundColor(Palette.text)
                Text(verbatim: run.title).font(size: 12).foregroundColor(Palette.muted)
            }
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Pixels(260)))], spacing: Spacing.sm) {
                    ForEach(run.lanes, id: \.id) { lane in
                        CandidateCard(model: model, run: run, lane: lane)
                    }
                }
            }
        }
        .padding(insets(top: 12, right: 14, bottom: 12, left: 14))
        .frame(maxWidth: .infinity, maxHeight: 280, alignment: .topLeading)
        .background(Palette.ground)
    }
}

/// The node kinds (read-only until editing arrives).
struct PaletteView: Component {
    static let groups: [(String, [String])] = [
        ("INPUTS", ["Flow input", "Repo"]),
        ("STEPS", ["Prompt", "Fan-out", "Shell command"]),
        ("CHECKS", ["Gate"]),
        ("DECIDE", ["Judge", "You pick"]),
    ]

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Self.groups, id: \.0) { group in
                Text(verbatim: group.0).font(size: 11).foregroundColor(Palette.muted)
                    .padding(lengthInsets(top: 10, right: 4, bottom: 4, left: 4))
                ForEach(group.1, id: \.self) { item in
                    HStack(spacing: 0) {
                        Text(verbatim: item).font(size: 13).foregroundColor(Palette.text)
                            .accessibilityIdentifier("palette.\(item)")
                    }
                    .padding(insets(top: 6, right: 8, bottom: 6, left: 8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(Hsla.rgb(0x171a1f)))
                    .cornerRadius(6)
                }
            }
            Spacer()
        }
        .padding(insets(top: 12, right: 10, bottom: 12, left: 10))
        .frame(width: Pixels(200), alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .background(Palette.panel)
    }
}

/// The selected node's title, kind and configuration, read-only.
struct InspectorView: Component {
    let draft: FlowDraft

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let id = draft.selection, let node = draft.flow.node(id) {
                Text(verbatim: node.kindLabel).font(size: 11).foregroundColor(Palette.muted)
                Text(verbatim: node.title).font(size: 16).foregroundColor(Palette.text)
                    .accessibilityIdentifier("inspector.title")
                ScrollView(.vertical) {
                    Text(verbatim: Self.config(node)).font(Theme.mono(12)).foregroundColor(Palette.body)
                        .accessibilityIdentifier("inspector.config")
                }
            } else {
                Text(verbatim: "Select a node to see its settings.").font(size: 12).foregroundColor(Palette.muted)
                    .accessibilityIdentifier("inspector.empty")
            }
            Spacer()
        }
        .padding(insets(top: 12, right: 14, bottom: 12, left: 14))
        .frame(width: Pixels(320), alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .background(Palette.panel)
    }

    static func config(_ node: Node) -> String {
        switch node.kind {
        case .flowInput(let c): return "name: \(c.name)\nsource: \(c.source == .githubIssue ? "GitHub issue" : "text")"
        case .repo: return "The run's worktree."
        case .prompt(let c), .judge(let c):
            var lines = ["model: \(c.model)"]
            if !c.candidates.isEmpty { lines.append("candidates: \(c.candidates.joined(separator: ", "))") }
            lines.append("tools: \(c.allowedTools.joined(separator: ", "))")
            if let turns = c.maxTurns { lines.append("max turns: \(turns)") }
            lines.append("\nprompt:\n\(c.prompt)")
            return lines.joined(separator: "\n")
        case .shell(let c), .gate(let c): return "command: \(c.command)"
        case .pick: return "Waits for you to pick a candidate."
        }
    }
}
