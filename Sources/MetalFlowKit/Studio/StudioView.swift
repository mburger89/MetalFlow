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
    /// Where this view's top-left corner is in the window, to place the drag's label from a window point.
    @State var origin = ScreenPoint(x: Pixels(0), y: Pixels(0))

    var content: some ElementGroup {
        let draft = draft
        VStack(spacing: 0) {
            StudioToolbar(model: model, draft: draft)
            Divider()
            if let problem = Self.problem(draft, launchError: model.studioLaunch.error) {
                Text(verbatim: problem).font(size: 12).foregroundColor(Palette.bad)
                    .accessibilityIdentifier("studio.validation")
                    .lineLimit(2)
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
                InspectorView(model: model, draft: draft, repos: model.repos)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 420, maxHeight: .infinity)
            }
            .splitViewAutosaveName("studio.panes")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .anchoredOverlay(
            isPresented: Binding(get: { draft.nodeSearch != nil }, set: { shown in if !shown { draft.closeNodeSearch() } }),
            at: draft.nodeSearch?.windowPoint ?? ScreenPoint(x: Pixels(0), y: Pixels(0)), in: .global) {
            NodeSearchPane(draft: draft)
        }
        .onGeometryChange(for: ScreenPoint.self, of: { $0.frame(in: .global).origin }) { origin = $0 }
        // Drawn here, not inside the canvas or palette, so neither clips the label being dragged.
        .overlay(alignment: .topLeading) { PaletteDragLabel(drag: draft.paletteDrag, origin: origin) }
    }
}

extension StudioBody {
    /// Why the flow cannot run: it does not validate, or it validates but cannot be launched from where it is.
    static func problem(_ draft: FlowDraft, launchError: String?) -> String? {
        if case .failure(let error) = draft.validation { return draft.flow.message(for: error) }
        return launchError
    }
}

/// The label of the palette row being dragged, under the pointer. Drawn at `StudioBody`'s root so neither the palette
/// nor the canvas clips it; it never takes a press. `origin` is the root's top-left corner in window points.
struct PaletteDragLabel: Component {
    let drag: PaletteDrag?
    let origin: ScreenPoint

    static let size = (width: Float(120), height: Float(28))

    var content: some ElementGroup {
        ZStack(alignment: .topLeading) {
            if let drag {
                Text(verbatim: drag.entry.label).font(size: 13).foregroundColor(Palette.text)
                    .frame(width: Pixels(Self.size.width), height: Pixels(Self.size.height))
                    .background(Palette.line)
                    .cornerRadius(6)
                    .offset(x: drag.windowPoint.x - origin.x - Pixels(Self.size.width / 2),
                            y: drag.windowPoint.y - origin.y - Pixels(Self.size.height / 2))
                    .accessibilityIdentifier("palette.drag")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
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
            .labelsHidden()
            .frame(width: Pixels(260))
            .accessibilityIdentifier("studio.runPicker")
            Button("Save") { Task { await model.saveDraft() } }
                .buttonStyle(.bordered)
                .keyboardShortcut("s")
                .accessibilityIdentifier("studio.save")
                .disabled(!valid)
            Button("Copy to\u{2026}") { Task { await model.copyDraft() } }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("studio.copyTo")
                .disabled(draft.url == nil)
            let launch = model.studioLaunch
            ForEach(launch.fields, id: \.name) { field in
                controls.control(for: field)
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

    private var controls: LaunchFieldControls {
        LaunchFieldControls(
            model: model, idPrefix: "studio",
            value: { field in Binding(get: { model.studioValue(field) }, set: { model.studioValues[field.name] = $0 }) },
            submit: { Task { await model.launchFromStudio() } }, repoWidth: Pixels(140), textWidth: Pixels(160))
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
