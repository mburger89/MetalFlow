import MetalFlowKit
import MetalUI
import MetalUITesting
import Testing

/// The app's real root element in a headless window, as `main.swift` builds it, with the menu commands and the
/// quit guard installed on the window's app.
@MainActor
func appWindow(model: AppModel, size: Size<Pixels> = metalFlowWindowSize,
               options: HeadlessPlatformWindow.Options = .init()) throws -> TestWindow {
    let window = try TestWindow(size: size, colorScheme: .dark, options: options) { rootView(model: model) }
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
