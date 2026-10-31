import MetalFlowCore
import MetalUI

/// The node kinds. Clicking one adds a node at the canvas centre and selects it.
struct PaletteView: Component {
    let draft: FlowDraft

    var content: some ElementGroup {
        let draft = draft
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(PaletteKind.groups, id: \.title) { group in
                Text(verbatim: group.title).font(size: 11).foregroundColor(Palette.muted)
                    .padding(insets(top: 10, right: 4, bottom: 4, left: 4))
                ForEach(group.items, id: \.idPrefix) { item in
                    Button(item.label) { draft.addNode(item) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("palette.\(item.idPrefix)")
                        .frame(maxWidth: .infinity, alignment: .leading)
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
