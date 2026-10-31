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

        try window.click(window.element(identifier: "nav.studio"))
        try await window.runUntilIdle()
        _ = try window.element(identifier: "studio")
    }
}
