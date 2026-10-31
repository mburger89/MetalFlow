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
            if let problem = Self.problem(draft) {
                Text(verbatim: problem).font(size: 12).foregroundColor(Palette.bad)
                    .accessibilityIdentifier("studio.validation")
                    .lineLimit(2)
                    .padding(insets(top: 6, right: 14, bottom: 6, left: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.bad.opacity(0.14))
            }
            if let message = model.studioLaunch.error {
                Text(verbatim: message).font(size: 12).foregroundColor(Palette.bad)
                    .accessibilityIdentifier("studio.launchError")
                    .lineLimit(2)
                    .padding(insets(top: 6, right: 14, bottom: 6, left: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                InspectorView(draft: draft, repos: model.repos)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 420, maxHeight: .infinity)
            }
            .splitViewAutosaveName("studio.panes")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension StudioBody {
    /// Why the flow cannot run: it does not validate, or it validates but cannot be launched from where it is.
    static func problem(_ draft: FlowDraft) -> String? {
        if case .failure(let error) = draft.validation { return error.errorDescription ?? "\(error)" }
        do { _ = try draft.flow.launchFields(location: draft.location) } catch { return draft.flow.message(for: error) }
        return nil
    }
}

/// Flow name, file, run picker, Save, and the launch row: one control per launch field and Launch.
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
            let launch = model.studioLaunch
            ForEach(launch.fields, id: \.name) { field in
                studioControl(field)
            }
            if let resolved = model.studioResolvedRepo {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repo").font(size: 12).foregroundColor(Palette.muted)
                    Text(verbatim: resolved).foregroundColor(Palette.text)
                        .accessibilityIdentifier("studio.repo.resolved")
                }
            }
            Button("▶ Launch") { Task { await model.launchFromStudio() } }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("studio.launch")
                .disabled(!valid || !launch.canLaunch)
        }
        .padding(insets(top: 8, right: 14, bottom: 8, left: 14))
        .background(Palette.chrome)
    }

    @ElementBuilder
    private func studioControl(_ field: LaunchField) -> some ElementGroup {
        let binding = Binding(
            get: { model.studioValue(field) }, set: { model.studioValues[field.name] = $0 })
        if field.kind == .repo {
            if model.repos.isEmpty {
                Text("No repos yet").foregroundColor(Palette.muted).accessibilityIdentifier("studio.field.repo")
            } else {
                Picker("", selection: binding) {
                    ForEach(model.repos, id: \.path) { url in
                        Text(verbatim: url.lastPathComponent).tag(url.path)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: Pixels(140))
                .accessibilityIdentifier("studio.field.repo")
            }
        } else {
            TextField(field.name, text: binding)
                .onSubmit { Task { await model.launchFromStudio() } }
                .frame(width: Pixels(160))
                .accessibilityIdentifier("studio.field.\(field.name)")
        }
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
