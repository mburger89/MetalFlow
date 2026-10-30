import Foundation

/// Derives git branch names for flow runs and candidate lanes.
public enum BranchNaming {
    /// Lowercase ASCII slug: runs of other characters become `-`, trimmed, at most 30 characters; empty gives `run`.
    public static func slug(_ title: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in title.unicodeScalars {
            let isAlnum = scalar.isASCII && ((scalar.value >= 0x61 && scalar.value <= 0x7A)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A))
            if isAlnum {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(Character(scalar).lowercased())
            } else {
                pendingDash = true
            }
        }
        var result = String(out.prefix(30))
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "run" : result
    }

    /// Branch for a run, `flow/<issue>-<slug>` or `flow/<slug>`; a numeric suffix (`-2`, `-3`, ...) avoids names in `existing`.
    public static func runBranch(issue: Int?, title: String, existing: Set<String>) -> String {
        let base = "flow/" + (issue.map { "\($0)-" } ?? "") + slug(title)
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// Branch for a candidate lane of a run.
    public static func laneBranch(run: String, lane: String) -> String {
        "\(run)--\(lane)"
    }
}
