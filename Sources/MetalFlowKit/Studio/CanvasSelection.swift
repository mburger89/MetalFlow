import MetalFlowCore
import MetalUI

/// What is selected on the canvas: nodes and notes, or one wire. View state: never undone, never saved.
struct CanvasSelection: Equatable {
    /// The selected nodes.
    var nodes: Set<NodeID>
    /// The selected notes and frames.
    var notes: Set<NoteID>
    /// The selected wire. A wire is never selected with nodes or notes.
    var wire: Wire?

    init(nodes: Set<NodeID> = [], notes: Set<NoteID> = [], wire: Wire? = nil) {
        self.nodes = nodes
        self.notes = notes
        self.wire = wire
    }

    /// Whether nothing is selected.
    var isEmpty: Bool { nodes.isEmpty && notes.isEmpty && wire == nil }

    /// How many nodes and notes are selected.
    var count: Int { nodes.count + notes.count }

    /// This selection combined with the `hit` nodes and notes as `mode` says: replaced by them, with them added, or
    /// with each of them toggled in or out. A selected wire is dropped.
    func applying(_ hit: Set<NodeID>, notes hitNotes: Set<NoteID> = [], mode: SelectionMode) -> CanvasSelection {
        switch mode {
        case .replace: CanvasSelection(nodes: hit, notes: hitNotes)
        case .add: CanvasSelection(nodes: nodes.union(hit), notes: notes.union(hitNotes))
        case .toggle:
            CanvasSelection(nodes: nodes.symmetricDifference(hit), notes: notes.symmetricDifference(hitNotes))
        }
    }
}

/// How a click or a box combines what it hits with the selection: no modifier replaces it, ⇧ adds to it and ⌘
/// toggles each item in or out. ⌘ wins when both are held.
enum SelectionMode: Equatable {
    case replace
    case add
    case toggle

    /// The mode `modifiers` ask for.
    init(_ modifiers: EventModifiers) {
        if modifiers.contains(.command) {
            self = .toggle
        } else if modifiers.contains(.shift) {
            self = .add
        } else {
            self = .replace
        }
    }
}

/// The ⇧/⌘/plain drag box: a faint accent fill with an accent outline, in canvas-local screen points.
struct SelectionBoxView: Component {
    let rect: CanvasRect

    var content: some ElementGroup {
        Rectangle()
            .fill(Palette.accent.opacity(0.08))
            .overlay { Rectangle().strokeBorder(Palette.accent, lineWidth: Pixels(1)) }
            .frame(width: Pixels(Float(rect.w)), height: Pixels(Float(rect.h)))
            .offset(x: Pixels(Float(rect.x)), y: Pixels(Float(rect.y)))
            .allowsHitTesting(false)
    }
}
