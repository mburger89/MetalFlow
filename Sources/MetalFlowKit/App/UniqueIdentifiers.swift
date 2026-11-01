import Foundation

/// Accessibility ids that are unique within a list.
enum UniqueIdentifiers {
    /// `ids` in order with later repeats suffixed `-2`, `-3`, …; the first occurrence keeps its id.
    static func dedupe(_ ids: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return ids.map { id in
            let count = (seen[id] ?? 0) + 1
            seen[id] = count
            return count == 1 ? id : "\(id)-\(count)"
        }
    }
}
