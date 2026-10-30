import MetalFlowKit
import MetalUI

// One model for the whole app, created here and handed to the views.
@MainActor
func makeModel() -> AppModel {
    AppModel(client: LiveEngineClient.makeDefault(), notifier: NoopNotifier())
}

let model = makeModel()
let app = try App()
try app.openWindow(title: "MetalFlow", size: metalFlowWindowSize, minSize: metalFlowMinimumSize) {
    rootView(model: model)
}
app.run()
