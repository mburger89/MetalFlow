import MetalFlowCore
import MetalUI

/// The home screen: launch bar, needs-you cards, open items, running runs and recent history, beside the
/// activity feed.
public struct DashboardView: Component {
    let model: AppModel

    /// Creates the dashboard over a model.
    public init(model: AppModel) { self.model = model }

    public var content: some ElementGroup {
        HStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 22) {
                    LaunchBar(model: model)
                    NeedsYouSection(model: model)
                    WorkingSection(model: model)
                    RunningSection(model: model)
                    FinishedList(model: model)
                }
                .padding(insets(top: 18, right: 20, bottom: 20, left: 20))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ActivityFeed(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.ground)
        .overlay(alignment: .topLeading) {
            // An identifier on a container would replace those of everything inside it (MetalUI), so the
            // screen's marker is a zero-size element of its own.
            Spacer().frame(width: 0, height: 0).accessibilityIdentifier("dashboard")
        }
    }
}

/// Flows and runs the user has open, each with Open and a dismiss button.
struct WorkingSection: Component {
    let model: AppModel

    var content: some ElementGroup {
        if !model.workingOn.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(title: "WORKING ON", subtitle: "Flows and runs you have open", id: "working")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Pixels(240)))], spacing: Spacing.sm) {
                    ForEach(model.workingOn, id: \.self) { item in
                        WorkingChip(model: model, item: item)
                    }
                }
            }
        }
    }
}

/// One "working on" chip.
struct WorkingChip: Component {
    let model: AppModel
    let item: WorkingItem

    var content: some ElementGroup {
        let (type, title, what, id) = describe()
        HStack(spacing: 10) {
            Text(verbatim: type).font(size: 11).foregroundColor(Color(Hsla.rgb(0xb9c0ca)))
                .padding(lengthInsets(top: 2, right: 6, bottom: 2, left: 6))
                .background(Color(Hsla.rgb(0x1f232a))).cornerRadius(4)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title).font(size: 13).foregroundColor(Palette.text)
                    .accessibilityIdentifier(id)
                    .lineLimit(1)
                Text(verbatim: what).font(size: 12).foregroundColor(Palette.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Open") { open() }
                .buttonStyle(.bordered).accessibilityIdentifier("\(id).open")
            Button("×") { model.dismiss(item) }
                .buttonStyle(.bordered).accessibilityIdentifier("\(id).dismiss")
        }
        .padding(insets(top: 10, right: 12, bottom: 10, left: 12))
        .background(Palette.panel)
        .cornerRadius(10)
        .border(Color(Hsla.rgb(0x262a31)), width: 1)
    }

    private func describe() -> (String, String, String, String) {
        switch item {
        case .flow(let url):
            (
                "FLOW", url.deletingPathExtension().lastPathComponent, "Open in Flow Studio",
                "working.flow.\(url.path)"
            )
        case .run(let id):
            ("RUN", model.runs[id]?.title ?? "Run", model.runs[id].map(Self.statusText) ?? "", "working.run.\(id.rawValue)")
        }
    }

    private func open() {
        switch item {
        case .run(let id): model.open(run: id)
        case .flow(let url): model.open(flow: url)
        }
    }

    static func statusText(_ run: Run) -> String {
        switch run.status {
        case .running: "Running"
        case .needsYou: "Needs you"
        case .merged(let lane): "Merged \(lane.uppercased())"
        case .discarded: "Discarded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .completed: "Completed"
        }
    }
}

/// Running runs in an adaptive grid of cards.
struct RunningSection: Component {
    let model: AppModel

    var content: some ElementGroup {
        if !model.running.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(title: "RUNNING", subtitle: "Each run in its own worktree", id: "running")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Pixels(300)))], spacing: Spacing.sm) {
                    ForEach(model.running, id: \.id) { run in
                        RunCard(model: model, run: run)
                    }
                }
            }
        }
    }
}
