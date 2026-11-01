import Foundation
import MetalUI

/// The save-destination panel: where a flow that has no file yet is saved. An in-window overlay like the Open Flow
/// panel. Escape or Cancel cancels the save.
struct SavePanel: Component {
    let model: AppModel
    @FocusState var focused: Bool

    var content: some ElementGroup {
        ZStack {
            Palette.chrome.opacity(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { model.chooseSaveDestination(nil) }
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Save flow to").font(size: 15).foregroundColor(Palette.text)
                Button("Library") { model.chooseSaveDestination(.library) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("save.dest.library")
                let repos = model.repos
                let ids = UniqueIdentifiers.dedupe(repos.map { "save.dest.\($0.lastPathComponent)" })
                ForEach(Array(zip(repos, ids)), id: \.0.path) { repo, id in
                    Button(repo.lastPathComponent) { model.chooseSaveDestination(.repo(repo)) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(id)
                }
                Button("Add repo\u{2026}") { model.requestAddRepo(.saveDestination) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("save.dest.add")
                Button("Cancel") { model.chooseSaveDestination(nil) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("save.cancel")
            }
            .padding(Edges(all: Spacing.lg))
            .frame(width: Pixels(420))
            .background(Palette.panel)
            .cornerRadius(14)
            .border(Palette.line, width: 1)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("save.panel")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused($focused)
        .onKeyPress(.escape) { model.chooseSaveDestination(nil); return .handled }
        .task { focused = true }
    }
}
