import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct SessionLimitTests {
    func fixture(limit: Int = 4) async throws -> (AppModel, FakeEngineClient, TestWindow) {
        let client = FakeEngineClient()
        client.limit.value = limit
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        try await window.runUntilIdle()
        return (model, client, window)
    }

    @Test func limitLoadsFromClient() async throws {
        let (model, _, _) = try await fixture(limit: 6)
        #expect(model.maxSessions == 6)
    }

    @Test func changingLimitReachesClientAndSaves() async throws {
        let (model, client, _) = try await fixture()
        await model.setMaxSessions(8)
        #expect(model.maxSessions == 8)
        #expect(client.limit.value == 8)
        #expect(await client.calls.contains("setMaxSessions(8)"))
        #expect(model.notice == nil)
    }

    @Test func failedSaveKeepsTheOldLimit() async throws {
        let (model, client, _) = try await fixture(limit: 4)
        await client.setFailure(FakeFailure())
        await model.setMaxSessions(9)
        #expect(model.maxSessions == 4)
        #expect(client.limit.value == 4)
        #expect(model.notice?.kind == .error)
    }

    @Test func limitControlShowsOnDashboard() async throws {
        let (_, _, window) = try await fixture(limit: 5)
        _ = try window.element(identifier: "dashboard.maxSessions")
    }
}
