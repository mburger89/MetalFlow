import AppKit
import MetalFlowKit
import MetalUI

// One model for the whole app, created here and handed to the views.
@MainActor
func makeModel(notifier: Notifier) -> AppModel {
    AppModel(client: LiveEngineClient.makeDefault(), notifier: notifier)
}

let notifier = UserNotificationsNotifier()
let model = makeModel(notifier: notifier)
// Only a notification click brings the window forward; nothing else activates the app.
model.activateApp = { NSApp.activate() }
let app = try App()
installCommands(on: app, model: model)
let window = try app.openWindow(title: "MetalFlow", size: metalFlowWindowSize, minSize: metalFlowMinimumSize) {
    rootView(model: model)
}
installQuitHandling(on: app, window: window, model: model)
Task { await notifier.requestAuthorization() }
app.run()
