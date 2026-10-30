import MetalFlowKit
import MetalUI
import MetalUITesting

/// The app's real root element in a headless window, as `main.swift` builds it, with the menu commands and the
/// quit guard installed on the window's app.
@MainActor
func appWindow(model: AppModel, size: Size<Pixels> = metalFlowWindowSize) throws -> TestWindow {
    let window = try TestWindow(size: size, colorScheme: .dark) { rootView(model: model) }
    installCommands(on: window.testApp.app, model: model)
    installQuitHandling(on: window.testApp.app, model: model)
    return settled(window)
}

/// Draws the frames a window needs to settle.
@MainActor
func settled(_ window: TestWindow) -> TestWindow {
    window.tick()
    window.tick()
    return window
}
