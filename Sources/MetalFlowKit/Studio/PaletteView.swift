import MetalFlowCore
import MetalUI

/// The node kinds. Clicking one adds a node at the canvas centre and selects it; dragging one onto the canvas adds it
/// centred on the drop.
struct PaletteView: Component {
    let draft: FlowDraft

    var content: some ElementGroup {
        let draft = draft
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(PaletteKind.groups, id: \.title) { group in
                Text(verbatim: group.title).font(size: 11).foregroundColor(Palette.muted)
                    .padding(insets(top: 10, right: 4, bottom: 4, left: 4))
                ForEach(group.items, id: \.idPrefix) { item in
                    // A label under one gesture, not a Button: a Button's click would hold the drag off.
                    PaletteRow(draft: draft, kind: item)
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
    let kind: PaletteKind

    var content: some ElementGroup {
        let draft = draft, kind = kind
        Text(verbatim: kind.label).font(size: 13).foregroundColor(Palette.text)
            .padding(insets(top: 6, right: 10, bottom: 6, left: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.line)
            .cornerRadius(6)
            .gesture(DragGesture(minimumDistance: Pixels(0), coordinateSpace: .global)
                .onChanged { draft.movePaletteDrag(kind, from: $0.startLocation, to: $0.location) }
                .onEnded { draft.endPaletteDrag(kind, from: $0.startLocation, at: $0.location) }
                .onCancelled { draft.cancelPaletteDrag() })
            .accessibilityIdentifier("palette.\(kind.idPrefix)")
            .accessibilityAction { draft.addNode(kind) }
    }
}
