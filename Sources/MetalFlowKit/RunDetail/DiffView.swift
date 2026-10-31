import Foundation
import MetalFlowCore
import MetalUI

/// The most input lines a diff shows.
let diffLineLimit = 2000


/// Splits a unified diff into one coloured chunk per hunk. Lines before the first `@@` (the file headers) form a
/// leading chunk, all muted. `+` lines are green on a faint green, `-` lines red on a faint red, `@@` and the
/// rest muted. At most 2000 input lines are shown; a last chunk then says how many were left out.
func diffAttributed(_ text: String) -> [AttributedString] {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    let hidden = max(0, lines.count - diffLineLimit)
    if hidden > 0 { lines.removeLast(hidden) }

    var chunks: [AttributedString] = []
    var current = AttributedString()
    var hasLines = false
    var inHeader = true
    func flush() {
        if hasLines { chunks.append(current) }
        current = AttributedString()
        hasLines = false
    }
    for line in lines {
        if line.hasPrefix("@@") {
            flush()
            inHeader = false
        }
        var piece = AttributedString(line + "\n")
        piece.font = Theme.mono(12)
        if inHeader || line.hasPrefix("@@") {
            piece.foregroundColor = Palette.muted
        } else if line.hasPrefix("+") {
            piece.foregroundColor = Palette.ok
            piece.backgroundColor = Palette.ok.opacity(0.14)
        } else if line.hasPrefix("-") {
            piece.foregroundColor = Palette.bad
            piece.backgroundColor = Palette.bad.opacity(0.14)
        } else {
            piece.foregroundColor = Palette.body
        }
        current.append(piece)
        hasLines = true
    }
    flush()
    if hidden > 0 {
        var more = AttributedString("… \(hidden) more lines")
        more.font = Theme.mono(12)
        more.foregroundColor = Palette.muted
        chunks.append(more)
    }
    return chunks
}

/// A unified diff, one `Text` per hunk, in a vertical scroll view.
struct DiffView: Component {
    let chunks: [AttributedString]

    /// Parses `text` (do this once, not per frame, for big diffs: use `init(chunks:)`).
    init(text: String) { chunks = diffAttributed(text) }
    /// Shows already parsed chunks.
    init(chunks: [AttributedString]) { self.chunks = chunks }

    var content: some ElementGroup {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if chunks.isEmpty {
                    Text(verbatim: "No changes").font(size: 12).foregroundColor(Palette.muted)
                        .accessibilityIdentifier("diff.empty")
                }
                ForEach(Array(chunks.enumerated()), id: \.offset) { index, chunk in
                    Text(chunk).accessibilityIdentifier("diff.hunk.\(index)")
                }
            }
            .padding(Edges(all: Spacing.md))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: Pixels(360))
        .background(Palette.chrome)
        .cornerRadius(8)
        .border(Palette.line, width: 1)
    }
}

/// The open lane diff of `run`, if it is the one open: "Loading diff…" while it loads, then the diff. Shown under
/// the candidate cards on the run detail and in the Studio's candidates strip.
struct OpenDiffSection: Component {
    let model: AppModel
    let run: RunID

    var content: some ElementGroup {
        if let key = model.openDiff, key.run == run {
            if let chunks = model.diffChunks[key] {
                DiffView(chunks: chunks)
            } else {
                Text(verbatim: "Loading diff…").font(size: 12).foregroundColor(Palette.muted)
                    .accessibilityIdentifier("diff.loading")
            }
        }
    }
}
