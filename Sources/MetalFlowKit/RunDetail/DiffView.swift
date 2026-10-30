import Foundation
import MetalUI

/// The most input lines a diff shows.
let diffLineLimit = 2000

private let diffOK = Color(Hsla.rgb(0x56d364))
private let diffBad = Color(Hsla.rgb(0xff7b72))
private let diffMuted = Color(Hsla.rgb(0x9aa1ab))
private let diffMono = Font.custom("Menlo", size: 12)

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
        piece.font = diffMono
        if inHeader || line.hasPrefix("@@") {
            piece.foregroundColor = diffMuted
        } else if line.hasPrefix("+") {
            piece.foregroundColor = diffOK
            piece.backgroundColor = diffOK.opacity(0.14)
        } else if line.hasPrefix("-") {
            piece.foregroundColor = diffBad
            piece.backgroundColor = diffBad.opacity(0.14)
        } else {
            piece.foregroundColor = Color(Hsla.rgb(0xc9ced6))
        }
        current.append(piece)
        hasLines = true
    }
    flush()
    if hidden > 0 {
        var more = AttributedString("… \(hidden) more lines")
        more.font = diffMono
        more.foregroundColor = diffMuted
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
                    Text(verbatim: "No changes").font(size: 12).foregroundColor(diffMuted)
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
