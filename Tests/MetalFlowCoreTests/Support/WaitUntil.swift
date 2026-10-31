import Testing

/// Yields until `condition` holds, at most 200 000 times; records an issue naming `what` if it never does, so a
/// regression fails the test instead of hanging the suite.
@discardableResult
func waitUntil(_ what: String, _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<200_000 {
        if await condition() { return true }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(what)")
    return false
}
