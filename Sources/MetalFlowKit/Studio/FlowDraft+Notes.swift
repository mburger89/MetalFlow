import MetalFlowCore
import MetalUI

/// A note being typed into, and the text typed so far.
struct NoteEdit: Equatable {
    var id: NoteID
    var draft: String
}

extension FlowDraft {
    /// The note being typed into, if any.
    var editingNote: NoteID? { noteEdit?.id }

    /// The id `note<n>` with the smallest positive `n` no note uses.
    private func uniqueNoteID() -> NoteID {
        var n = 1
        while flow.notes.contains(where: { $0.id.rawValue == "note\(n)" }) { n += 1 }
        return NoteID(rawValue: "note\(n)")
    }

    /// Adds a note as one undo step, selects it and opens it for typing. With nodes selected it is a frame around
    /// them; otherwise a sticky centred on `point` (canvas-local screen points), or on the canvas centre.
    @discardableResult
    func addNote(at point: ScreenPoint? = nil) -> NoteID {
        commitNoteEdit()
        let id = uniqueNoteID()
        let rects = flow.nodes.filter { canvasSelection.nodes.contains($0.id) }.map(geometry.nodeRect)
        let note: FlowNote
        if let first = rects.first {
            let minX = rects.dropFirst().reduce(first.x) { min($0, $1.x) }
            let minY = rects.dropFirst().reduce(first.y) { min($0, $1.y) }
            let maxX = rects.dropFirst().reduce(first.maxX) { max($0, $1.maxX) }
            let maxY = rects.dropFirst().reduce(first.maxY) { max($0, $1.maxY) }
            let pad = NoteLayout.framePadding
            note = FlowNote(id: id, origin: CanvasPoint(x: minX - pad, y: minY - pad - NoteLayout.titleStrip),
                            width: maxX - minX + 2 * pad, height: maxY - minY + 2 * pad + NoteLayout.titleStrip,
                            surrounds: true)
        } else {
            let at = point ?? canvasSize.map { ScreenPoint(x: $0.width / 2, y: $0.height / 2) }
                ?? ScreenPoint(x: Pixels(0), y: Pixels(0))
            let centre = geometry.toCanvas(at)
            note = FlowNote(id: id, origin: CanvasPoint(x: (centre.x - NoteLayout.stickyWidth / 2).rounded(),
                                                         y: (centre.y - NoteLayout.stickyHeight / 2).rounded()),
                            width: NoteLayout.stickyWidth, height: NoteLayout.stickyHeight, surrounds: false)
        }
        apply("add \(id.rawValue)", coalescing: false) { $0.notes.append(note) }
        beginEditingNote(id)
        return id
    }

    /// Sets a note's text as one undo step.
    func setNoteText(_ id: NoteID, _ text: String) {
        apply("edit \(id.rawValue)", coalescing: false) { flow in
            if let i = flow.notes.firstIndex(where: { $0.id == id }) { flow.notes[i].text = text }
        }
    }

    /// The nodes whose centres lie inside a frame; none for a sticky. Worked out when needed, never saved.
    func members(of note: FlowNote) -> [NodeID] {
        note.surrounds ? geometry.nodes(centredIn: geometry.noteRect(note), flow: flow) : []
    }

    // MARK: Editing

    /// Opens note `id` for typing, making it the whole selection. Any edit already open is committed first. Does
    /// nothing, returning false, for a note that is not there.
    @discardableResult
    func beginEditingNote(_ id: NoteID) -> Bool {
        commitNoteEdit()
        guard let note = flow.notes.first(where: { $0.id == id }) else { return false }
        canvasSelection = CanvasSelection(notes: [id])
        noteEdit = NoteEdit(id: id, draft: note.text)
        return true
    }

    /// The field's text changed.
    func updateNoteDraft(_ text: String) {
        noteEdit?.draft = text
    }

    /// Ends the edit, writing the text as one undo step; nothing is recorded when it is unchanged. A frame's title is
    /// one line: line breaks become spaces. A note left empty stays.
    func commitNoteEdit() {
        guard let edit = noteEdit else { return }
        noteEdit = nil
        let surrounds = flow.notes.first { $0.id == edit.id }?.surrounds ?? false
        let text = surrounds ? edit.draft.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ")
            : edit.draft
        setNoteText(edit.id, text)
    }

    /// Ends the edit and throws the text away.
    func cancelNoteEdit() {
        noteEdit = nil
    }
}
