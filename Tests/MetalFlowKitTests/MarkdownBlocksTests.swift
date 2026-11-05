import Testing
@testable import MetalFlowKit

@Suite struct MarkdownBlocksTests {
    @Test func emptyInputGivesNoBlocks() {
        #expect(MarkdownBlocks.parse("") == [])
        #expect(MarkdownBlocks.parse("\n\n  \n") == [])
    }

    @Test func headingsOfEveryLevel() {
        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            #expect(MarkdownBlocks.parse("\(hashes) Title") == [.heading(level: level, text: "Title")])
        }
        #expect(MarkdownBlocks.parse("####### seven") == [.paragraph("####### seven")])
    }

    @Test func headingStripsTrailingHashes() {
        #expect(MarkdownBlocks.parse("## Title ##") == [.heading(level: 2, text: "Title")])
        #expect(MarkdownBlocks.parse("# C#") == [.heading(level: 1, text: "C#")])
    }

    @Test func hashWithoutSpaceIsAParagraph() {
        #expect(MarkdownBlocks.parse("#text") == [.paragraph("#text")])
    }

    @Test func blankLinesSplitParagraphs() {
        #expect(MarkdownBlocks.parse("one\n\ntwo") == [.paragraph("one"), .paragraph("two")])
    }

    @Test func softLineBreakStaysInOneParagraph() {
        #expect(MarkdownBlocks.parse("one\ntwo\nthree") == [.paragraph("one\ntwo\nthree")])
    }

    @Test func bulletsWithEveryMarker() {
        #expect(MarkdownBlocks.parse("- a\n* b\n+ c") == [.bullets(["a", "b", "c"])])
    }

    @Test func nestedBulletsAreFlattened() {
        #expect(MarkdownBlocks.parse("- a\n  - b\n    - c\n- d") == [.bullets(["a", "b", "c", "d"])])
    }

    @Test func numberedList() {
        #expect(MarkdownBlocks.parse("1. one\n2. two\n10. ten") == [.numbered(["one", "two", "ten"])])
    }

    @Test func listsSeparateFromParagraphs() {
        #expect(MarkdownBlocks.parse("intro\n- a\n- b\noutro") == [
            .paragraph("intro"), .bullets(["a", "b"]), .paragraph("outro"),
        ])
    }

    @Test func fencedCodeWithLanguage() {
        #expect(MarkdownBlocks.parse("```swift\nlet x = 1\n```") == [.code(language: "swift", text: "let x = 1")])
    }

    @Test func fencedCodeWithoutLanguage() {
        #expect(MarkdownBlocks.parse("```\na\n\nb\n```") == [.code(language: nil, text: "a\n\nb")])
    }

    @Test func tildeFenceNeedsMatchingCloser() {
        #expect(MarkdownBlocks.parse("~~~\n```\n~~~") == [.code(language: nil, text: "```")])
    }

    @Test func unclosedFenceRunsToTheEnd() {
        #expect(MarkdownBlocks.parse("```\nstill code\n# not heading") == [
            .code(language: nil, text: "still code\n# not heading"),
        ])
    }

    @Test func codeContentsAreNotParsedAsMarkdown() {
        let md = "```\n# heading\n- bullet\n> quote\n---\n```"
        #expect(MarkdownBlocks.parse(md) == [.code(language: nil, text: "# heading\n- bullet\n> quote\n---")])
    }

    @Test func blockQuote() {
        #expect(MarkdownBlocks.parse("> one\n> two\n>three") == [.quote("one\ntwo\nthree")])
    }

    @Test func ruleIsNotABullet() {
        #expect(MarkdownBlocks.parse("---") == [.rule])
        #expect(MarkdownBlocks.parse("* * *") == [.rule])
        #expect(MarkdownBlocks.parse("___") == [.rule])
        #expect(MarkdownBlocks.parse("a\n\n---\n\nb") == [.paragraph("a"), .rule, .paragraph("b")])
    }

    @Test func unsupportedSyntaxIsPlainParagraphs() {
        #expect(MarkdownBlocks.parse("| a | b |\n|---|---|") == [.paragraph("| a | b |\n|---|---|")])
        #expect(MarkdownBlocks.parse("<div>hi</div>") == [.paragraph("<div>hi</div>")])
    }

    @Test func mixedDocument() {
        let md = "# T\n\ntext\n\n- a\n\n1. x\n\n> q\n\n---\n"
        #expect(MarkdownBlocks.parse(md) == [
            .heading(level: 1, text: "T"), .paragraph("text"), .bullets(["a"]),
            .numbered(["x"]), .quote("q"), .rule,
        ])
    }
}
