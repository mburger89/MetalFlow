import Foundation
import Testing
@testable import MetalFlowKit

@Suite struct MarkdownViewTests {
    @Test func headingSizeFallsWithLevel() {
        let sizes = (1...6).map { MarkdownStyle.headingSize(level: $0) }
        #expect(sizes == sizes.sorted(by: >))
        #expect(Set(sizes.dropLast()).count == 5)
        #expect(sizes[0] > 13)
        guard case let .heading(level, _) = MarkdownBlocks.parse("## Two").first else {
            Issue.record("expected a heading"); return
        }
        #expect(MarkdownStyle.headingSize(level: level) == MarkdownStyle.headingSize(level: 2))
    }

    @Test func markersMatchListKind() {
        #expect(MarkdownStyle.marker(numbered: false, index: 3) == "•")
        #expect(MarkdownStyle.marker(numbered: true, index: 0) == "1.")
        #expect(MarkdownStyle.marker(numbered: true, index: 2) == "3.")
    }

    @Test func listItemKeepsBoldAsRuns() {
        guard case let .bullets(items) = MarkdownBlocks.parse("- a **bold** word").first else {
            Issue.record("expected bullets"); return
        }
        let attributed = MarkdownStyle.inline(items[0])
        #expect(String(attributed.characters) == "a bold word")
        let bold = attributed.runs.filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold.map { String(attributed[$0.range].characters) } == ["bold"])
    }

    @Test func inlineParseFailureFallsBackToVerbatim() {
        struct Boom: Error {}
        let shown = MarkdownStyle.inline("raw **text**") { _ in throw Boom() }
        #expect(String(shown.characters) == "raw **text**")
    }

    @Test func ordinaryTextParsesWithoutFallback() {
        #expect(String(MarkdownStyle.inline("plain").characters) == "plain")
    }
}
