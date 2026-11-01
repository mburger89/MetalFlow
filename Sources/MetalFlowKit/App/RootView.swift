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
        // One folder dialog for every "Add repo": a cancel calls nothing, only writes the binding false.
        .fileImporter(isPresented: Binding(
            get: { model.addRepoRequest != nil },
            set: { shown in if !shown { model.addRepoDialogEnded() } }),
            allowedContentTypes: [.folder]) { result in
            let folder = try? result.get()
            let purpose = model.takeAddRepoPurpose()
            guard let purpose else { return }
            Task { await model.finishAddRepo(folder, purpose: purpose) }
        }
        .fileDialogConfirmationLabel("Add Repository")
        .fileDialogMessage(model.addRepoRequest?.dialogMessage ?? "")
        // Escape presses the `.cancel` button below. A dismissal that presses no button lands in `set`, which hears it
        // before any button action: `alertDismissed` looks after the buttons have run.
        .alert("Save changes to this flow?", isPresented: Binding(
            get: { model.pendingAction != nil },
            set: { shown in if !shown { Task { model.alertDismissed() } } })) {
            let target = model.pendingAction
            // Save and Discard take the pending action at once, so the dismissal check sees it answered.
            Button("Save") {
                if let target { model.pendingAction = nil; Task { await model.resolvePending(target, .save) } }
            }
            Button("Discard", role: .destructive) {
                if let target { model.pendingAction = nil; Task { await model.resolvePending(target, .discard) } }
            }
            Button("Cancel", role: .cancel) { model.cancelPending() }
        } message: {
            Text("The open flow has unsaved edits.")
        }
        .alert("Quit MetalFlow?", isPresented: Binding(
            get: { model.quitPending },
            set: { shown in if !shown { Task { model.alertDismissed() } } })) {
            Button("Quit", role: .destructive) { model.quitPending = false; Task { await model.confirmQuit() } }
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
                Text("Dashboard").accessibilityIdentifier("nav.dashboard").tag(Screen.dashboard)
                Text("Flow Studio").accessibilityIdentifier("nav.studio").tag(Screen.studio)
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
        if model.isSavePanelVisible {
            SavePanel(model: model)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
