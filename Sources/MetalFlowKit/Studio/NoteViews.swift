import MetalFlowCore
import MetalUI

/// A sticky on the canvas, drawn at its position for the zoom but not the pan, as the node cards are, and equatable
/// for the same reason. A tinted card with its body wrapped inside, a ring in the accent when selected and the resize
/// handle then. While it is being typed into the field covers the text. No shadows.
struct StickyView: Component, @MainActor Equatable {
    let note: FlowNote
    let zoom: Double
    let selected: Bool
    let editing: Bool

    var content: some ElementGroup {
        let z = zoom
        let w = Pixels(Float(note.width * z)), h = Pixels(Float(note.height * z))
        let handle = NoteLayout.handle
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Palette.warn.opacity(0.2))
            if !editing {
                Text(verbatim: note.text).font(size: 13 * z).foregroundColor(Palette.text)
                    .padding(Edges(all: Pixels(Float(NoteLayout.textPadding * z))))
                    .frame(width: w, height: h, alignment: .topLeading)
                    .clipped()
            }
            Rectangle().strokeBorder(selected ? Palette.accent : Palette.warn.opacity(0.55),
                                     lineWidth: Pixels(selected ? 2 : 1))
            if selected {
                Rectangle().fill(Palette.accent)
                    .frame(width: Pixels(Float(handle)), height: Pixels(Float(handle)))
                    .offset(x: w - Pixels(Float(handle)), y: h - Pixels(Float(handle)))
                    .accessibilityIdentifier("note.\(note.id.rawValue).handle")
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note.\(note.id.rawValue)")
        .offset(x: Pixels(Float(note.origin.x * z)), y: Pixels(Float(note.origin.y * z)))
    }
}

/// A frame on the canvas: a faint fill with a border and a title strip, drawn under the wires and the nodes. Equatable
/// like `StickyView`.
struct FrameView: Component, @MainActor Equatable {
    let note: FlowNote
    let zoom: Double
    let selected: Bool
    let editing: Bool

    var content: some ElementGroup {
        let z = zoom
        let w = Pixels(Float(note.width * z)), h = Pixels(Float(note.height * z))
        let handle = NoteLayout.handle
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Palette.accent.opacity(0.06))
            Text(verbatim: editing ? "" : note.text).font(size: 12 * z).foregroundColor(Palette.text)
                .lineLimit(1)
                .padding(insets(top: 0, right: 8 * z, bottom: 0, left: 8 * z))
                .frame(width: w, height: Pixels(Float(NoteLayout.titleStrip * z)), alignment: .leading)
                .background(Palette.accent.opacity(0.22))
                .clipped()
            Rectangle().strokeBorder(selected ? Palette.accent : Palette.accent.opacity(0.5),
                                     lineWidth: Pixels(selected ? 2 : 1))
            if selected {
                Rectangle().fill(Palette.accent)
                    .frame(width: Pixels(Float(handle)), height: Pixels(Float(handle)))
                    .offset(x: w - Pixels(Float(handle)), y: h - Pixels(Float(handle)))
                    .accessibilityIdentifier("note.\(note.id.rawValue).handle")
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("note.\(note.id.rawValue)")
        .offset(x: Pixels(Float(note.origin.x * z)), y: Pixels(Float(note.origin.y * z)))
    }
}

/// The field of the note being typed into, or nothing. It sits over the canvas's surface, never inside it: the surface
/// is a key region, and a field inside it would pass its keys to the canvas's own handler. A sticky is typed into with
/// a `TextEditor` over the whole note (⌘Return commits), a frame with a `TextField` over its title strip (Return
/// commits). Esc cancels, and losing focus commits. It takes focus as it appears.
struct NoteEditorLayer: Component {
    let draft: FlowDraft

    var content: some ElementGroup {
        let g = draft.geometry
        let editors = draft.noteEdit.flatMap { edit in
            draft.flow.notes.first { $0.id == edit.id }.map { NoteEditorField(draft: draft, edit: edit, note: $0, geometry: g) }
        }.map { [$0] } ?? []
        ZStack(alignment: .topLeading) {
            // Keyed by the note, so each edit is a new field and asks for focus again.
            ForEach(editors, id: \.edit.id.rawValue) { $0 }
        }
        // As big as the canvas and no bigger: a field running past it must neither resize the canvas nor draw over
        // the palette or inspector.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

struct NoteEditorField: Component {
    let draft: FlowDraft
    let edit: NoteEdit
    let note: FlowNote
    let geometry: CanvasGeometry
    @FocusState var focused: Bool

    var content: some ElementGroup {
        let draft = draft
        let z = geometry.zoom
        let origin = geometry.toScreen(CanvasPoint(x: note.origin.x, y: note.origin.y))
        if note.surrounds {
            titleField(draft)
                .font(size: 12 * z)
                .focused($focused)
                .onKeyPress(.escape) {
                    draft.cancelNoteEdit()
                    return .handled
                }
                .onSubmit { draft.commitNoteEdit() }
                .frame(width: Pixels(Float(note.width * z)), height: Pixels(Float(NoteLayout.titleStrip * z)))
                .offset(x: origin.x, y: origin.y)
                .accessibilityIdentifier("note.editor")
                .onAppear { focused = true }
                .onChange(of: focused) { was, now in if was, !now { draft.commitNoteEdit() } }
        } else {
            stickyEditor(draft)
                .font(size: 13 * z)
                .focused($focused)
                .onKeyPress(keys: [.return]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    draft.commitNoteEdit()
                    return .handled
                }
                .onKeyPress(.escape) {
                    draft.cancelNoteEdit()
                    return .handled
                }
                .frame(width: Pixels(Float(note.width * z)), height: Pixels(Float(note.height * z)))
                .offset(x: origin.x, y: origin.y)
                .accessibilityIdentifier("note.editor")
                .onAppear { focused = true }
                .onChange(of: focused) { was, now in if was, !now { draft.commitNoteEdit() } }
        }
    }

    /// The sticky's field, opening with the selection the draft holds (the caret at the end) where MetalUI can take one.
    private func stickyEditor(_ draft: FlowDraft) -> TextEditor {
        if #available(macOS 15, *) {
            return TextEditor("Note", text: edit.draft, selection: draft.noteSelection as? TextSelection,
                              onChange: { draft.updateNoteDraft($0) },
                              onSelectionChange: { draft.noteSelectionChanged(AnyHashable($0)) })
        }
        return TextEditor("Note", text: edit.draft, onChange: { draft.updateNoteDraft($0) })
    }

    /// The frame title's field, opening with its text selected where MetalUI can take a selection.
    private func titleField(_ draft: FlowDraft) -> TextField {
        if #available(macOS 15, *) {
            return TextField("Title", text: edit.draft, selection: draft.noteSelection as? TextSelection,
                             onChange: { draft.updateNoteDraft($0) },
                             onSelectionChange: { draft.noteSelectionChanged(AnyHashable($0)) })
        }
        return TextField("Title", text: edit.draft, onChange: { draft.updateNoteDraft($0) })
    }
}
