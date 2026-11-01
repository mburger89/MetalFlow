import Foundation
import MetalFlowCore
import MetalUI

/// The Open Flow panel (⌘O): a layer over the window with the catalog's flow files and Cancel.
/// MetalUI has no sheet, so this is an in-window overlay. Clicking outside it, or Escape, cancels.
struct OpenFlowPanel: Component {
    let model: AppModel
    @FocusState var focused: Bool

    var content: some ElementGroup {
        ZStack {
            Palette.chrome.opacity(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { model.hideOpenFlow() }
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Open flow").font(size: 15).foregroundColor(Palette.text)
                if model.catalog.isEmpty {
                    Text("No flows").foregroundColor(Palette.muted)
                        .accessibilityIdentifier("openFlow.empty")
                } else {
                    let ids = UniqueIdentifiers.dedupe(model.catalog.map(Self.identifier(of:)))
                    ForEach(Array(zip(model.catalog, ids)), id: \.0.id) { entry, id in
                        Button(LaunchBar.title(of: entry)) { model.chooseEntry(entry) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(id)
                    }
                }
                Button("Cancel") { model.hideOpenFlow() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("openFlow.cancel")
            }
            .padding(Edges(all: Spacing.lg))
            .frame(width: Pixels(420))
            .background(Palette.panel)
            .roundedBorder(Palette.line, radius: 14)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("openFlow.panel")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused($focused)
        .onKeyPress(.escape) { model.hideOpenFlow(); return .handled }
        .task { focused = true }
    }
}

extension OpenFlowPanel {
    /// `openFlow.builtin` for the built-in, otherwise `openFlow.<file name>`; the panel suffixes repeats (see `UniqueIdentifiers`).
    static func identifier(of entry: FlowEntry) -> String {
        entry.file.map { "openFlow.\($0.lastPathComponent)" } ?? "openFlow.builtin"
    }
}
