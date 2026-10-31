import MetalFlowKit
import MetalUI
import MetalUITesting
import Testing

/// The app's real root element in a headless window, as `main.swift` builds it, with the menu commands and the
/// quit guard installed on the window's app.
@MainActor
func appWindow(model: AppModel, size: Size<Pixels> = metalFlowWindowSize) throws -> TestWindow {
    let window = try TestWindow(size: size, colorScheme: .dark) { rootView(model: model) }
    installCommands(on: window.testApp.app, model: model)
    installQuitHandling(on: window.testApp.app, window: window.window, model: model)
    return settled(window)
}

/// Draws the frames a window needs to settle.
@MainActor
func settled(_ window: TestWindow) -> TestWindow {
    window.tick()
    window.tick()
    return window
}

/// Yields until `condition` holds, at most 200 000 times; records an issue naming `what` if it never does.
@MainActor
@discardableResult
func waitUntil(_ what: String, _ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200_000 {
        if condition() { return true }
        await Task.yield()
    }
    Issue.record("timed out waiting for \(what)")
    return false
}
