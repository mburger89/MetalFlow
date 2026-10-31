import Foundation
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
                let files = model.catalog.compactMap(\.file)
                if files.isEmpty {
                    Text("No flows").foregroundColor(Palette.muted)
                        .accessibilityIdentifier("openFlow.empty")
                } else {
                    ForEach(files, id: \.self) { url in
                        Button(url.lastPathComponent) { model.chooseFlow(url) }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("openFlow.\(url.lastPathComponent)")
                    }
                }
                Button("Cancel") { model.hideOpenFlow() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("openFlow.cancel")
            }
            .padding(Edges(all: Spacing.lg))
            .frame(width: Pixels(420))
            .background(Palette.panel)
            .cornerRadius(14)
            .border(Palette.line, width: 1)
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
