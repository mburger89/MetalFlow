import Foundation

/// One file of a unified diff.
struct DiffFile: Equatable {
    let path: String
    let added: Int
    let removed: Int
    let hunks: [DiffHunk]
}

/// One `@@` block of a file: its header line and its numbered lines.
struct DiffHunk: Equatable {
    let header: String
    let lines: [DiffLine]
}

/// A line of a hunk. `oldNumber` is nil for an added line, `newNumber` for a removed one. `text` has no marker.
struct DiffLine: Equatable {
    enum Kind { case context, added, removed }
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

/// Splits a unified diff into files, hunks and numbered lines (the viewer's model; the inline view keeps its own
/// chunks). Reads git diffs and plain `---`/`+++` patches.
enum DiffFiles {
    /// How many input lines the cap leaves out: the same `diffLineLimit` as the inline view.
    static func hiddenLines(_ text: String) -> Int { max(0, inputLines(text).count - diffLineLimit) }

    static func parse(_ text: String) -> [DiffFile] {
        var lines = inputLines(text)
        if lines.count > diffLineLimit { lines.removeLast(lines.count - diffLineLimit) }

        var files: [FileBuilder] = []
        // Lines of the current hunk still owed by its header; while > 0 a `---`/`+++` line is content, not a header.
        var oldLeft = 0, newLeft = 0
        var oldNumber = 0, newNumber = 0

        for line in lines {
            if oldLeft > 0 || newLeft > 0, let kind = lineKind(line) {
                add(kind, line, &files, &oldNumber, &newNumber)
                if kind != .added { oldLeft -= 1 }
                if kind != .removed { newLeft -= 1 }
                continue
            }
            if line.hasPrefix("\\") { continue }   // "\ No newline at end of file"
            if line.hasPrefix("diff --git ") {
                var file = FileBuilder()
                file.fromGit = true
                if let range = line.range(of: " b/", options: .backwards) {
                    file.path = String(line[range.upperBound...])
                }
                if let range = line.range(of: " a/"), let end = line.range(of: " b/", options: .backwards),
                   range.upperBound <= end.lowerBound {
                    file.oldPath = String(line[range.upperBound..<end.lowerBound])
                }
                files.append(file)
                oldLeft = 0; newLeft = 0
            } else if line.hasPrefix("@@") {
                guard let counts = hunkCounts(line) else { continue }
                if files.isEmpty { files.append(FileBuilder()) }
                oldNumber = counts.oldStart; newNumber = counts.newStart
                oldLeft = counts.oldCount; newLeft = counts.newCount
                files[files.count - 1].hunks.append(HunkBuilder(header: line))
            } else if line.hasPrefix("--- ") {
                // A plain patch has no `diff --git`; its next file starts at its `---` once the last one has hunks.
                if files.isEmpty || (!files[files.count - 1].fromGit && !files[files.count - 1].hunks.isEmpty) {
                    files.append(FileBuilder())
                }
                let name = headerName(line)
                if name != "/dev/null" { files[files.count - 1].oldPath = name }
            } else if line.hasPrefix("+++ ") {
                if files.isEmpty { files.append(FileBuilder()) }
                let name = headerName(line)
                let last = files.count - 1
                if name == "/dev/null" {
                    if let old = files[last].oldPath { files[last].path = old }   // a deleted file
                } else if !files[last].fromGit {
                    files[last].path = name
                }
            } else if !files.isEmpty, !files[files.count - 1].hunks.isEmpty, let kind = lineKind(line) {
                // A hunk longer than its header says: keep the lines rather than lose them.
                add(kind, line, &files, &oldNumber, &newNumber)
            }
        }
        return files.map { $0.file }
    }

    // MARK: - Private

    private struct HunkBuilder {
        let header: String
        var lines: [DiffLine] = []
    }

    private struct FileBuilder {
        var path = ""
        var oldPath: String?
        var fromGit = false
        var hunks: [HunkBuilder] = []

        var file: DiffFile {
            let all = hunks.flatMap(\.lines)
            return DiffFile(path: path, added: all.filter { $0.kind == .added }.count,
                            removed: all.filter { $0.kind == .removed }.count,
                            hunks: hunks.map { DiffHunk(header: $0.header, lines: $0.lines) })
        }
    }

    private static func inputLines(_ text: String) -> [String] {
        if text.allSatisfy(\.isWhitespace) { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// An empty line inside a hunk is a context line whose trailing space an editor stripped.
    private static func lineKind(_ line: String) -> DiffLine.Kind? {
        if line.isEmpty { return .context }
        switch line.first {
        case "+": return .added
        case "-": return .removed
        case " ": return .context
        default: return nil
        }
    }

    private static func add(_ kind: DiffLine.Kind, _ line: String, _ files: inout [FileBuilder],
                            _ oldNumber: inout Int, _ newNumber: inout Int) {
        let text = String(line.dropFirst())
        let entry: DiffLine
        switch kind {
        case .context: entry = DiffLine(kind: kind, oldNumber: oldNumber, newNumber: newNumber, text: text)
        case .added: entry = DiffLine(kind: kind, oldNumber: nil, newNumber: newNumber, text: text)
        case .removed: entry = DiffLine(kind: kind, oldNumber: oldNumber, newNumber: nil, text: text)
        }
        if kind != .added { oldNumber += 1 }
        if kind != .removed { newNumber += 1 }
        let last = files.count - 1
        files[last].hunks[files[last].hunks.count - 1].lines.append(entry)
    }

    /// The path of a `--- a/x` or `+++ b/x` line: without the a/ or b/ and without git's tab-separated timestamp.
    private static func headerName(_ line: String) -> String {
        var name = String(line.dropFirst(4))
        if let tab = name.firstIndex(of: "\t") { name = String(name[..<tab]) }
        if name.hasPrefix("a/") || name.hasPrefix("b/") { name = String(name.dropFirst(2)) }
        return name
    }

    /// `@@ -a,b +c,d @@`: the start and count of both sides; a count left out is 1.
    private static func hunkCounts(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let old = range(parts[1].dropFirst()), let new = range(parts[2].dropFirst()) else { return nil }
        return (old.start, old.count, new.start, new.count)
    }

    private static func range(_ text: Substring) -> (start: Int, count: Int)? {
        let numbers = text.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = numbers.first.flatMap({ Int($0) }) else { return nil }
        if numbers.count > 1 { return Int(numbers[1]).map { (start, $0) } }
        return (start, 1)
    }
}
