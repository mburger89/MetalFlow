import Foundation
import MetalUI

/// Pure display decisions for Markdown blocks, kept apart from drawing so they can be tested.
enum MarkdownStyle {
    /// Point size of a heading: larger for a lower level, 13 (body) from level 6.
    static func headingSize(level: Int) -> Double {
        switch level {
        case ...1: 22
        case 2: 19
        case 3: 16
        case 4: 15
        case 5: 14
        default: 13
        }
    }

    /// The marker before list item `index` (zero-based).
    static func marker(numbered: Bool, index: Int) -> String {
        numbered ? "\(index + 1)." : "•"
    }

    /// Inline Markdown as runs. If the parse throws, the text is returned verbatim (decision 6).
    static func inline(_ text: String,
                       parse: (String) throws -> AttributedString = Self.parseInline) -> AttributedString {
        (try? parse(text)) ?? AttributedString(text)
    }

    static func parseInline(_ text: String) throws -> AttributedString {
        try AttributedString(markdown: text,
                             options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }
}

/// Renders Markdown text as a vertical stack of blocks.
public struct MarkdownView: Component {
    let text: String

    public init(text: String) { self.text = text }

    public var content: some ElementGroup {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: Spacing.sm) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// One block of Markdown.
struct MarkdownBlockView: Component {
    let block: MarkdownBlock

    var content: some ElementGroup {
        switch block {
        case let .heading(level, text):
            Text(MarkdownStyle.inline(text))
                .font(size: MarkdownStyle.headingSize(level: level))
                .fontWeight(.bold)
                .foregroundColor(Palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .paragraph(text):
            Text(MarkdownStyle.inline(text)).font(size: 13).foregroundColor(Palette.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .bullets(items):
            MarkdownList(items: items, numbered: false)
        case let .numbered(items):
            MarkdownList(items: items, numbered: true)
        case let .code(_, text):
            Text(verbatim: text).font(Theme.mono(12)).foregroundColor(Palette.body)
                .padding(Edges(all: Spacing.sm))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.line)
                .cornerRadius(6)
        case let .quote(text):
            HStack(alignment: .top, spacing: Spacing.sm) {
                Rectangle().fill(Palette.muted).frame(width: Pixels(3))
                Text(MarkdownStyle.inline(text)).font(size: 13).foregroundColor(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .rule:
            Rectangle().fill(Palette.line).frame(height: Pixels(1)).frame(maxWidth: .infinity)
        }
    }
}

/// A bulleted or numbered list.
struct MarkdownList: Component {
    let items: [String]
    let numbered: Bool

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Text(verbatim: MarkdownStyle.marker(numbered: numbered, index: index))
                        .font(size: 13).foregroundColor(Palette.muted)
                    Text(MarkdownStyle.inline(item)).font(size: 13).foregroundColor(Palette.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
