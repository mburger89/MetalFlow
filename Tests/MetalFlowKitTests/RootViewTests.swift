import Testing
import MetalUI
import MetalUITesting
@testable import MetalFlowKit

@MainActor
@Suite struct RootViewTests {
    @Test func rootShowsDashboardAndSwitchesToStudio() async throws {
        let model = AppModel(client: FakeEngineClient(), notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        _ = try window.element(identifier: "dashboard")
        #expect((try? window.element(identifier: "studio")) == nil)

        let nav = try window.element(identifier: "nav")
        // The picker is one element; its segments split it in half, so click the right half.
        let frame = nav.frame
        window.click(at: Point(x: frame.origin.x + frame.size.width * 0.75, y: frame.origin.y + frame.size.height / 2))
        try await window.runUntilIdle()
        _ = try window.element(identifier: "studio")
    }
}
