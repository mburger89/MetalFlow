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

/// The dashboard or the studio. Real screens arrive in later tasks.
struct ScreenBody: Component {
    let model: AppModel

    var content: some ElementGroup {
        switch model.screen {
        case .dashboard:
            Text("Dashboard").foregroundColor(Palette.muted).accessibilityIdentifier("dashboard")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .studio:
            Text("Flow Studio").foregroundColor(Palette.muted).accessibilityIdentifier("studio")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The window's one root element (`openWindow` wants an `Element`, not a component).
@MainActor
public func rootView(model: AppModel) -> some Element {
    VStack(spacing: 0) {
        RootView(model: model)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}
