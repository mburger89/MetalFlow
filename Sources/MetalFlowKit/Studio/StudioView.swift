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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("studio")
    }
}

struct StudioBody: Component {
    let model: AppModel
    let draft: FlowDraft

    var content: some ElementGroup {
        VStack(spacing: 0) {
            StudioToolbar(model: model, draft: draft)
            Divider()
            if case .failure(let error) = draft.validation {
                HStack(spacing: 0) {
                    Text(verbatim: error.errorDescription ?? "\(error)").font(size: 12).foregroundColor(Palette.bad)
                        .accessibilityIdentifier("studio.validation")
                        .lineLimit(2)
                }
                .padding(insets(top: 6, right: 14, bottom: 6, left: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.bad.opacity(0.14))
            }
            // Palette | canvas | inspector; the divider positions persist across launches (UserDefaults).
            HSplitView {
                PaletteView(draft: draft)
                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 280, maxHeight: .infinity)
                VStack(spacing: 0) {
                    CanvasView(model: model, draft: draft)
                    if let run = model.studioShownRun, !run.lanes.isEmpty {
                        Divider()
                        CandidatesStrip(model: model, run: run)
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                InspectorView(draft: draft)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 420, maxHeight: .infinity)
            }
            .splitViewAutosaveName("studio.panes")
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
            TextField("Flow name", text: Binding(
                get: { draft.flow.name },
                set: { value in draft.edit("name") { $0.name = value } }))
                .frame(width: Pixels(240))
                .accessibilityIdentifier("studio.name")
            Text(verbatim: Self.fileText(draft)).font(size: 12).foregroundColor(Palette.muted)
                .accessibilityIdentifier("studio.file")
            Spacer()
            Picker("", selection: Binding(
                get: { model.studioShownRun?.id.rawValue ?? "" },
                set: { value in model.studioRun = model.studioRuns.first { $0.id.rawValue == value }?.id })) {
                Text("Definition only").tag("")
                ForEach(model.studioRuns, id: \.id) { run in
                    Text(verbatim: "Showing \(run.title)").tag(run.id.rawValue)
                }
            }
            .pickerStyle(.menu)
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
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Pixels(260)))], spacing: Spacing.sm) {
                        ForEach(run.lanes, id: \.id) { lane in
                            CandidateCard(model: model, run: run, lane: lane)
                        }
                    }
                    OpenDiffSection(model: model, run: run.id)
                }
            }
        }
        .padding(insets(top: 12, right: 14, bottom: 12, left: 14))
        .frame(maxWidth: .infinity, maxHeight: 280, alignment: .topLeading)
        .background(Palette.ground)
    }
}
