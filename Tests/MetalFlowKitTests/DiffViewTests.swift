import Foundation
import MetalUI
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct DiffViewTests {
    let sample = """
    diff --git a/a.swift b/a.swift
    --- a/a.swift
    +++ b/a.swift
    @@ -1,2 +1,2 @@
     keep
    -old
    +new
    @@ -9,1 +9,1 @@
    -x
    +y
    """

    func plain(_ s: AttributedString) -> String { String(s.characters) }

    @Test func diffAttributedColoursLines() {
        let chunks = diffAttributed(sample)
        #expect(chunks.count == 3, "headers, then one chunk per hunk")
        #expect(plain(chunks[0]).hasPrefix("diff --git"))
        #expect(plain(chunks[1]).hasPrefix("@@ -1,2"))
        #expect(plain(chunks[2]).hasPrefix("@@ -9,1"))

        func runs(_ chunk: AttributedString) -> [(String, Color?, Color?)] {
            chunk.runs.map { (String(chunk[$0.range].characters), $0.foregroundColor, $0.backgroundColor) }
        }
        // Headers are muted, including the "+++" line.
        for (_, fg, bg) in runs(chunks[0]) {
            #expect(fg == Palette.muted)
            #expect(bg == nil)
        }
        let hunk = runs(chunks[1])
        // Adjacent lines with equal attributes merge into one run, so look at each line's own text.
        let added = hunk.first { $0.0.contains("+new") }
        let removed = hunk.first { $0.0.contains("-old") }
        let header = hunk.first { $0.0.contains("@@") }
        #expect(added?.1 == Palette.ok)
        #expect(added?.2 != nil)
        #expect(removed?.1 == Palette.bad)
        #expect(removed?.2 != nil)
        #expect(header?.1 == Palette.muted)
        #expect(header?.2 == nil)
    }

    @Test func diffTruncatesLongOutput() {
        let body = (1...2500).map { "+line \($0)" }.joined(separator: "\n")
        let chunks = diffAttributed("@@ -0,0 +1,2500 @@\n" + body)
        let all = chunks.map(plain).joined()
        #expect(all.contains("+line 1999"))
        #expect(!all.contains("+line 2000\n"))
        #expect(plain(chunks.last!) == "… 501 more lines")
        // 2000 input lines are kept: the header and 1999 added lines.
        #expect(chunks.count == 2)
    }

    @Test func emptyDiffHasNoChunks() {
        #expect(diffAttributed("").isEmpty)
    }
}
