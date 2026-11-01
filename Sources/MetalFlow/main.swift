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
let app = try App()
installCommands(on: app, model: model)
let window = try app.openWindow(title: "MetalFlow", size: metalFlowWindowSize, minSize: metalFlowMinimumSize) {
    rootView(model: model)
}
installQuitHandling(on: app, window: window, model: model)
// Only a notification click brings the window forward; nothing else activates the app. Activating the app
// does not raise a window (WA-A), so the main window is ordered front as well.
model.activateApp = {
    app.activate()
    window.makeKeyAndOrderFront()
}
// "Open PR" on a finished run's detail opens the pull request in the user's browser.
model.openURL = { NSWorkspace.shared.open($0) }
Task { await notifier.requestAuthorization() }
app.run()
