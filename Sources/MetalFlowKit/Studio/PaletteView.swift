import MetalFlowCore
import MetalUI

/// The node kinds and Note. Clicking one adds it at the canvas centre and selects it; dragging one onto the canvas adds it
/// centred on the drop.
struct PaletteView: Component {
    let draft: FlowDraft

    var content: some ElementGroup {
        let draft = draft
        let groups = draft.visiblePaletteGroups
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Keys typed here stay in the field: it is focused, so the canvas's hover key region never sees them.
            TextField("Find a node", text: draft.paletteFilter, onChange: { draft.paletteFilter = $0 })
                .onSubmit { draft.addFirstPaletteMatch() }
                .onKeyPress(.escape) {
                    draft.paletteFilter = ""
                    return .handled
                }
                .frame(height: Pixels(30))
                .accessibilityIdentifier("palette.find")
            if groups.isEmpty {
                Text(verbatim: "No matches").font(size: 12).foregroundColor(Palette.muted)
                    .padding(insets(top: 10, right: 4, bottom: 4, left: 4))
                    .accessibilityIdentifier("palette.empty")
            }
            ForEach(groups, id: \.title) { group in
                Text(verbatim: group.title).font(size: 11).foregroundColor(Palette.muted)
                    .padding(insets(top: 10, right: 4, bottom: 4, left: 4))
                ForEach(group.items, id: \.idPrefix) { item in
                    // A label under one gesture, not a Button: a Button's click would hold the drag off.
                    PaletteRow(draft: draft, entry: item)
                }
            }
            Spacer()
        }
        .padding(insets(top: 12, right: 10, bottom: 12, left: 10))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .background(Palette.panel)
    }
}

/// One palette row: a label that adds on a click and drags onto the canvas. Under 4 points of movement a press is a
/// click.
struct PaletteRow: Component {
    let draft: FlowDraft
    let entry: PaletteEntry

    var content: some ElementGroup {
        let draft = draft, entry = entry
        Text(verbatim: entry.label).font(size: 13).foregroundColor(Palette.text)
            .padding(insets(top: 6, right: 10, bottom: 6, left: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.line)
            .cornerRadius(6)
            .gesture(DragGesture(minimumDistance: Pixels(0), coordinateSpace: .global)
                .onChanged { draft.movePaletteDrag(entry, from: $0.startLocation, to: $0.location) }
                .onEnded { draft.endPaletteDrag(entry, from: $0.startLocation, at: $0.location) }
                .onCancelled { draft.cancelPaletteDrag() })
            .accessibilityIdentifier("palette.\(entry.idPrefix)")
            .accessibilityAction { draft.add(entry) }
    }
}
