import MetalUI

/// The window's root: top bar, then the screen the model selects.
public struct RootView: Component {
    let model: AppModel

    /// Creates the root over a model.
    public init(model: AppModel) { self.model = model }

    public var content: some ElementGroup {
        VStack(spacing: 0) {
            TopBar(model: model)
            Divider()
            ScreenBody(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
        .task { await model.start() }
        .alert("Save changes to this flow?", isPresented: Binding(
            get: { model.pendingAction != nil },
            set: { if !$0 { model.pendingAction = nil } })) {
            let target = model.pendingAction
            Button("Save") { if let target { Task { await model.resolvePending(target, .save) } } }
            Button("Discard", role: .destructive) { if let target { Task { await model.resolvePending(target, .discard) } } }
            Button("Cancel", role: .cancel) { model.pendingAction = nil }
        } message: {
            Text("The open flow has unsaved edits.")
        }
        .alert("Quit MetalFlow?", isPresented: Binding(
            get: { model.quitPending },
            set: { _ in })) {
            Button("Quit", role: .destructive) { Task { await model.confirmQuit() } }
            Button("Cancel", role: .cancel) { model.cancelQuit() }
        } message: {
            Text(verbatim: model.quitMessage)
        }
    }
}

/// App name, the Dashboard | Flow Studio switch and the running / needs-you counter.
struct TopBar: Component {
    let model: AppModel

    var content: some ElementGroup {
        HStack(spacing: Spacing.lg) {
            Text("MetalFlow").font(size: 15).foregroundColor(Palette.text)
            Picker("View", selection: Binding(get: { model.screen }, set: { model.screen = $0 })) {
                Text("Dashboard").tag(Screen.dashboard)
                Text("Flow Studio").tag(Screen.studio)
            }
            .pickerStyle(.segmented)
            .frame(width: Pixels(240))
            .accessibilityIdentifier("nav")
            Spacer()
            Text("\(model.running.count) running · \(model.needsYou.count) need you")
                .font(size: 13)
                .foregroundColor(model.needsYou.isEmpty ? Palette.muted : Palette.warn)
                .accessibilityIdentifier("counter")
        }
        .padding(Edges(top: Spacing.sm, right: Spacing.lg, bottom: Spacing.sm, left: Spacing.lg))
        .background(Palette.chrome)
    }
}

/// The dashboard or the studio.
struct ScreenBody: Component {
    let model: AppModel

    var content: some ElementGroup {
        switch model.screen {
        case .dashboard:
            if let id = model.selectedRun, model.runs[id] != nil {
                RunDetailView(model: model, run: id)
            } else {
                DashboardView(model: model)
            }
        case .studio:
            StudioView(model: model)
        }
    }
}

/// The window's one root element (`openWindow` wants an `Element`, not a component).
@MainActor
public func rootView(model: AppModel) -> some Element {
    ZStack {
        RootView(model: model)
        if model.isOpenFlowVisible {
            OpenFlowPanel(model: model)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
