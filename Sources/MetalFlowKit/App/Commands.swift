import MetalUI

/// What quitting should do given how many runs are running.
public enum QuitDecision: Equatable, Sendable {
    /// Nothing is running: quit at once.
    case now
    /// Runs are running: ask first, with this message.
    case ask(String)
}

/// Quitting stops running runs, so with any running the user is asked first.
public func quitDecision(runningCount: Int) -> QuitDecision {
    switch runningCount {
    case ...0: .now
    case 1: .ask("1 run is still running. Quitting stops it — you can resume later.")
    default: .ask("\(runningCount) runs are still running. Quitting stops them — you can resume later.")
    }
}

extension AppModel {
    /// The answer to ⌘Q: quit now, or hold the quit until the alert is answered.
    public func requestTerminate() -> CloseRequestReply {
        switch quitDecision(runningCount: running.count) {
        case .now: return .now
        case .ask(let message): quitMessage = message; quitPending = true; return .later
        }
    }

    /// Quit: suspends every running run (stopped, resumable on the next launch), then lets the app end.
    public func confirmQuit() async {
        let ids = running.map(\.id)
        isQuitting = true
        quitPending = false
        for id in ids { await client.suspend(id) }
        replyToTerminate(true)
    }

    /// Cancel: the app keeps running.
    public func cancelQuit() {
        quitPending = false
        replyToTerminate(false)
    }
}

/// Installs the File, Edit and Run menus. Every action is a model method.
@MainActor
public func installCommands(on app: App, model: AppModel) {
    app.commands {
        CommandGroup(after: .newItem) {
            Button("New Flow") { model.newFlow() }.keyboardShortcut("n")
            Button("Open Flow…") { model.showOpenFlow() }.keyboardShortcut("o")
            Button("Save") { Task { await model.saveDraft() } }
                .keyboardShortcut("s")
                .disabled(!model.canSave)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo)
            Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.primary, .shift]).disabled(!model.canRedo)
        }
        CommandMenu("Run") {
            Button("Launch…") { model.focusLaunch() }.keyboardShortcut("l")
            Button("Go to Dashboard") { model.goToDashboard() }.keyboardShortcut("1")
            Button("Go to Studio") { model.goToStudio() }.keyboardShortcut("2")
        }
    }
}

/// Asks before ⌘Q ends the app while runs are running.
@MainActor
public func installQuitHandling(on app: App, model: AppModel) {
    model.replyToTerminate = { [weak app] in app?.replyToTerminateRequest($0) }
    app.onTerminateRequest = { model.requestTerminate() }
}
