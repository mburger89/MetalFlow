import Foundation
import Testing
@testable import MetalFlowKit

@Suite struct DiffFilesTests {
    let multi = """
    diff --git a/Sources/A.swift b/Sources/A.swift
    index 1..2 100644
    --- a/Sources/A.swift
    +++ b/Sources/A.swift
    @@ -3,3 +3,4 @@ func f()
     keep
    -old
    +new
    +extra
     tail
    @@ -20 +21 @@
    -x
    +y
    diff --git a/B.txt b/B.txt
    --- a/B.txt
    +++ b/B.txt
    @@ -1,2 +1,2 @@
     one
    -two
    +three
    """ + "\n"

    @Test func parsesSeveralFilesWithPathsAndCounts() {
        let files = DiffFiles.parse(multi)
        #expect(files.map(\.path) == ["Sources/A.swift", "B.txt"])
        #expect(files.map(\.added) == [3, 1])
        #expect(files.map(\.removed) == [2, 1])
        #expect(files[0].hunks.map(\.header) == ["@@ -3,3 +3,4 @@ func f()", "@@ -20 +21 @@"])
    }

    @Test func numbersEachLineFromTheHunkHeader() {
        let lines = DiffFiles.parse(multi)[0].hunks[0].lines
        #expect(lines == [
            DiffLine(kind: .context, oldNumber: 3, newNumber: 3, text: "keep"),
            DiffLine(kind: .removed, oldNumber: 4, newNumber: nil, text: "old"),
            DiffLine(kind: .added, oldNumber: nil, newNumber: 4, text: "new"),
            DiffLine(kind: .added, oldNumber: nil, newNumber: 5, text: "extra"),
            DiffLine(kind: .context, oldNumber: 5, newNumber: 6, text: "tail")])
        // A header without counts means one line on each side.
        let single = DiffFiles.parse(multi)[0].hunks[1].lines
        #expect(single.first?.oldNumber == 20)
        #expect(single.last?.newNumber == 21)
    }

    @Test func aNewFileTakesItsPathFromTheDiffLine() {
        let text = "diff --git a/n.txt b/n.txt\nnew file mode 100644\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,2 @@\n+a\n+b\n"
        let files = DiffFiles.parse(text)
        #expect(files.map(\.path) == ["n.txt"])
        #expect(files[0].added == 2 && files[0].removed == 0)
        #expect(files[0].hunks[0].lines.map(\.newNumber) == [1, 2])
    }

    @Test func aDeletedFileKeepsItsOldPath() {
        let text = "diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\n--- a/gone.txt\n+++ /dev/null\n@@ -1,2 +0,0 @@\n-a\n-b\n"
        let files = DiffFiles.parse(text)
        #expect(files.map(\.path) == ["gone.txt"])
        #expect(files[0].removed == 2 && files[0].added == 0)
    }

    @Test func aDeletedFileWithoutGitHeaderUsesTheOldPath() {
        let files = DiffFiles.parse("--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-a\n")
        #expect(files.map(\.path) == ["gone.txt"])
    }

    @Test func noNewlineMarkersAreSkipped() {
        let text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n"
        let hunk = DiffFiles.parse(text)[0].hunks[0]
        #expect(hunk.lines.map(\.text) == ["a", "b"])
        #expect(hunk.lines.map(\.kind) == [.removed, .added])
    }

    @Test func aPlainPatchWithoutDiffGitParses() {
        let text = "--- a/x.txt\n+++ b/x.txt\n@@ -1 +1 @@\n-a\n+b\n--- a/y.txt\n+++ b/y.txt\n@@ -2 +2 @@\n-c\n+d\n"
        let files = DiffFiles.parse(text)
        #expect(files.map(\.path) == ["x.txt", "y.txt"])
        #expect(files.map(\.added) == [1, 1])
    }

    @Test func linesBeforeTheFirstDiffGitAreIgnored() {
        let files = DiffFiles.parse("preamble\nmore\n" + multi)
        #expect(files.map(\.path) == ["Sources/A.swift", "B.txt"])
    }

    @Test func dashedContentInsideAHunkIsNotAHeader() {
        let text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n--- removed text\n+++ added text\n"
        let file = DiffFiles.parse(text)[0]
        #expect(file.removed == 1 && file.added == 1)
        #expect(file.path == "f")
    }

    @Test func capsTheLinesAndCountsWhatWasLeftOut() {
        var text = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -0,0 +1,2500 @@\n"
        for i in 0..<2500 { text += "+line \(i)\n" }
        let files = DiffFiles.parse(text)
        // Four header lines count toward the cap, like the inline view.
        #expect(files[0].added == diffLineLimit - 4)
        #expect(DiffFiles.hiddenLines(text) == 2504 - diffLineLimit)
        #expect(DiffFiles.hiddenLines("+a\n") == 0)
    }

    @Test func emptyInputGivesNoFiles() {
        #expect(DiffFiles.parse("").isEmpty)
        #expect(DiffFiles.parse("  \n\n").isEmpty)
        #expect(DiffFiles.hiddenLines("") == 0)
    }
}
