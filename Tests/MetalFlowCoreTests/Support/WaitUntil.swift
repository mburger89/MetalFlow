import Testing

/// Yields until `condition` holds, at most for `timeout`; records an issue naming `what` if it never does, so a
/// regression fails the test instead of hanging the suite. A time limit, not a count of yields: a loaded machine
/// gets through many yields while a real `git` waits for the CPU.
@discardableResult
func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(what)")
    return false
}
