import Foundation
import MetalFlowCore
import MetalUI

/// The full-window diff viewer: a file list on the left and the chosen file's hunks, with old and new line numbers,
/// on the right. MetalUI has no sheet, so this is an in-window overlay like `OpenFlowPanel`: clicking outside the
/// panel, the Close button or Escape closes it.
struct DiffViewer: Component {
    let model: AppModel
    @FocusState var focused: Bool

    /// Width of one line-number column, wide enough for five digits in 12 pt Menlo.
    private static let numberWidth = Pixels(44)

    var content: some ElementGroup {
        let key = model.diffViewer
        let text = key.flatMap { model.diffTexts[$0] } ?? ""
        // Parsed per frame like any other component body; the line cap bounds the work.
        let files = DiffFiles.parse(text)
        let hidden = DiffFiles.hiddenLines(text)
        let selected = files.isEmpty ? 0 : min(max(0, model.diffViewerFile), files.count - 1)
        ZStack {
            Palette.chrome.opacity(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { model.closeDiffViewer() }
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.md) {
                    Text(verbatim: "Diff of \(key?.lane ?? "")").font(size: 15).foregroundColor(Palette.text)
                    Spacer()
                    Button("Close") { model.closeDiffViewer() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("diff.viewer.close")
                }
                if files.isEmpty {
                    Text(verbatim: "No changes").font(size: 12).foregroundColor(Palette.muted)
                        .accessibilityIdentifier("diff.viewer.empty")
                } else {
                    HStack(alignment: .top, spacing: Spacing.md) {
                        fileList(files, selected: selected)
                        hunkList(files[selected], hidden: hidden)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(Edges(all: Spacing.lg))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.panel)
            .roundedBorder(Palette.line, radius: 14)
            .padding(Edges(all: Spacing.lg))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("diff.viewer")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused($focused)
        .onKeyPress(.escape) { model.closeDiffViewer(); return .handled }
        .task { focused = true }
    }

    private func fileList(_ files: [DiffFile], selected: Int) -> some Element {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                    HStack(spacing: Spacing.sm) {
                        Text(verbatim: file.path).font(Theme.mono(12))
                            .foregroundColor(index == selected ? Palette.text : Palette.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: "+\(file.added)").font(Theme.mono(12)).foregroundColor(Palette.ok)
                        Text(verbatim: "\u{2212}\(file.removed)").font(Theme.mono(12)).foregroundColor(Palette.bad)
                    }
                    .padding(Edges(all: Spacing.sm))
                    .background(index == selected ? Palette.accent.opacity(0.18) : Palette.panel)
                    .cornerRadius(6)
                    .onTapGesture { model.diffViewerFile = index }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("diff.viewer.file.\(index)")
                }
            }
        }
        .frame(width: Pixels(320))
    }

    private func hunkList(_ file: DiffFile, hidden: Int) -> some Element {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: hunk.header).font(Theme.mono(12)).foregroundColor(Palette.muted)
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            row(line)
                        }
                    }
                }
                if hidden > 0 {
                    Text(verbatim: "… \(hidden) more lines").font(Theme.mono(12)).foregroundColor(Palette.muted)
                }
            }
            .padding(Edges(all: Spacing.md))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.chrome)
        .cornerRadius(8)
    }

    /// One line: both numbers muted in fixed columns, then the text coloured like the inline view.
    private func row(_ line: DiffLine) -> some Element {
        HStack(alignment: .top, spacing: Spacing.sm) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(coloured(line)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func number(_ value: Int?) -> some Element {
        Text(verbatim: value.map(String.init) ?? "").font(Theme.mono(12)).foregroundColor(Palette.muted)
            .frame(width: Self.numberWidth, alignment: .trailing)
    }

    /// The marker is shown again so a line reads as it does in the inline view.
    private func coloured(_ line: DiffLine) -> AttributedString {
        var piece: AttributedString
        switch line.kind {
        case .added:
            piece = AttributedString("+" + line.text)
            piece.foregroundColor = Palette.ok
            piece.backgroundColor = Palette.ok.opacity(0.14)
        case .removed:
            piece = AttributedString("-" + line.text)
            piece.foregroundColor = Palette.bad
            piece.backgroundColor = Palette.bad.opacity(0.14)
        case .context:
            piece = AttributedString(" " + line.text)
            piece.foregroundColor = Palette.body
        }
        piece.font = Theme.mono(12)
        return piece
    }
}
