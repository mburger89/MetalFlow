import Foundation
import MetalUI

/// The Open Flow panel (⌘O): a layer over the window with a repo picker, the repo's flows and Cancel.
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
                HStack(spacing: Spacing.sm) {
                    Text("Repo").font(size: 12).foregroundColor(Palette.muted)
                    if model.repos.isEmpty {
                        Text("No repos yet").foregroundColor(Palette.muted).accessibilityIdentifier("openFlow.repo")
                    } else {
                        Picker("", selection: Binding(
                            get: { model.launchForm.repo ?? model.repos[0] },
                            set: { url in let model = model; Task { await model.selectRepo(url) } })) {
                            ForEach(model.repos, id: \.self) { url in
                                Text(verbatim: url.lastPathComponent).tag(url)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("openFlow.repo")
                    }
                }
                if model.repoFlows.isEmpty {
                    Text("No flows in this repo").foregroundColor(Palette.muted)
                        .accessibilityIdentifier("openFlow.empty")
                } else {
                    ForEach(model.repoFlows, id: \.self) { url in
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
