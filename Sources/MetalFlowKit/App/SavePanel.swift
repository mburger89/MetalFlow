import Foundation
import MetalUI

/// The save-destination panel: where a flow that has no file yet is saved, or (in copy mode) where a saved flow is
/// copied, without its current location. An in-window overlay like the Open Flow panel. Escape or Cancel cancels.
struct SavePanel: Component {
    let model: AppModel
    @FocusState var focused: Bool

    var content: some ElementGroup {
        let copying: Bool
        let excluded: SaveDestination?
        if case .copy(let skip) = model.savePanelMode { (copying, excluded) = (true, skip) } else { (copying, excluded) = (false, nil) }
        return ZStack {
            Palette.chrome.opacity(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { model.chooseSaveDestination(nil) }
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(copying ? "Copy flow to" : "Save flow to").font(size: 15).foregroundColor(Palette.text)
                if excluded != .library {
                    Button("Library") { model.chooseSaveDestination(.library) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("save.dest.library")
                }
                let repos = model.repos
                // Ids are deduped over every repo, so leaving one out does not rename the others.
                let ids = UniqueIdentifiers.dedupe(repos.map { "save.dest.\($0.lastPathComponent)" })
                let skipped = excluded.flatMap { dest -> String? in
                    if case .repo(let root) = dest { root.standardizedFileURL.path } else { nil }
                }
                ForEach(Array(zip(repos, ids).filter { $0.0.standardizedFileURL.path != skipped }), id: \.0.path) { repo, id in
                    Button(repo.lastPathComponent) { model.chooseSaveDestination(.repo(repo)) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(id)
                }
                Button("Add repo\u{2026}") { model.requestAddRepo(copying ? .copyDestination : .saveDestination) }
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
