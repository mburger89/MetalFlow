import MetalFlowKit
import MetalUI
import MetalUITesting

/// The app's real root element in a headless window, as `main.swift` builds it.
@MainActor
func appWindow(model: AppModel, size: Size<Pixels> = metalFlowWindowSize) throws -> TestWindow {
    settled(try TestWindow(size: size, colorScheme: .dark) { rootView(model: model) })
}

/// Draws the frames a window needs to settle.
@MainActor
func settled(_ window: TestWindow) -> TestWindow {
    window.tick()
    window.tick()
    return window
}
