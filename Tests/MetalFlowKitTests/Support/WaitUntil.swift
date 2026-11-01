import Testing

/// Yields until `condition` holds, at most for `timeout`; records an issue naming `what` if it never does.
/// A time limit, not a count of yields: a loaded machine gets through many yields while real work waits for the CPU.
@MainActor
@discardableResult
func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(what)")
    return false
}
