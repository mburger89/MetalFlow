import MetalFlowCore
import MetalUI

/// The Tab search pane: a field, up to six matching node kinds with the highlighted one marked, and a caption line.
/// A fixed size, whatever it shows, so it does not jump as results change. `StudioBody` presents it with
/// `anchoredOverlay`, which flips it at the window's edges, closes it on Esc or a click outside, and keeps a click or
/// scroll on it from reaching the canvas.
struct NodeSearchPane: Component {
    let draft: FlowDraft
    @FocusState var focused: Bool

    static let width: Float = 280
    static let rowHeight: Float = 26
    static let fieldHeight: Float = 30
    static let captionHeight: Float = 16
    static let spacing: Float = 6
    static let padding: Float = 8
    static let rows = FlowDraft.nodeSearchRows
    static let height = fieldHeight + Float(rows) * rowHeight + captionHeight + spacing * 2 + padding * 2

    var content: some ElementGroup {
        let draft = draft
        let matches = draft.nodeSearchMatches
        let highlighted = draft.nodeSearch?.highlighted ?? 0
        let first = Self.firstVisible(highlighted: highlighted, count: matches.count)
        let visible = Array(matches.dropFirst(first).prefix(Self.rows))
        VStack(alignment: .leading, spacing: Pixels(Self.spacing)) {
            TextField("Add node", text: draft.nodeSearch?.query ?? "", onChange: { draft.setNodeSearchQuery($0) })
                .onSubmit { draft.confirmNodeSearch() }
                .focused($focused)
                .onAppear { focused = true }
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    draft.moveNodeSearch(by: press.key == .upArrow ? -1 : 1)
                    return .handled
                }
                .frame(height: Pixels(Self.fieldHeight))
                .accessibilityIdentifier("nodeSearch.field")
            VStack(alignment: .leading, spacing: Pixels(0)) {
                ForEach(visible, id: \.idPrefix) { kind in
                    NodeSearchRow(draft: draft, kind: kind, isHighlighted: kind == matches[highlighted.clamped(to: matches)])
                }
            }
            .frame(width: Pixels(Self.width - 2 * Self.padding), height: Pixels(Float(Self.rows) * Self.rowHeight),
                   alignment: .topLeading)
            Text(verbatim: Self.caption(shown: visible.count, total: matches.count))
                .font(size: 11).foregroundColor(Palette.muted)
                .frame(height: Pixels(Self.captionHeight))
        }
        .padding(Edges(all: Pixels(Self.padding)))
        .frame(width: Pixels(Self.width), height: Pixels(Self.height), alignment: .topLeading)
        .background(Palette.panel)
        .roundedBorder(Palette.line, radius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nodeSearch")
    }

    /// The index of the first row shown: the highlight stays in view, as the last row once the list scrolls.
    static func firstVisible(highlighted: Int, count: Int) -> Int {
        max(0, min(highlighted - rows + 1, count - rows))
    }

    static func caption(shown: Int, total: Int) -> String {
        if total == 0 { return "No matching nodes" }
        return total > shown ? "\(total - shown) more: keep typing, or \u{2191} \u{2193}" : ""
    }
}

private extension Int {
    /// `self` limited to the valid indices of `array`, 0 when it is empty.
    func clamped<T>(to array: [T]) -> Int { Swift.max(0, Swift.min(self, array.count - 1)) }
}

/// One match: its label, marked when highlighted. A click adds it.
struct NodeSearchRow: Component {
    let draft: FlowDraft
    let kind: PaletteKind
    let isHighlighted: Bool

    var content: some ElementGroup {
        let draft = draft, kind = kind
        Text(verbatim: kind.label).font(size: 13).foregroundColor(Palette.text)
            .padding(insets(top: 0, right: 8, bottom: 0, left: 8))
            .frame(maxWidth: .infinity, minHeight: Pixels(NodeSearchPane.rowHeight), maxHeight: Pixels(NodeSearchPane.rowHeight),
                   alignment: .leading)
            .background(isHighlighted ? Palette.line : Palette.panel)
            .cornerRadius(6)
            .onTapGesture { draft.confirmNodeSearch(kind) }
            .accessibilityIdentifier("nodeSearch.\(kind.idPrefix)")
            .accessibilityAction { draft.confirmNodeSearch(kind) }
    }
}
