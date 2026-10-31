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
    /// The answer to ⌘Q and to the window's close button (one window, so closing it is quitting). Unsaved
    /// Studio edits are asked about first (Save / Discard / Cancel), then running runs.
    public func requestTerminate() -> CloseRequestReply {
        if draft?.isDirty == true {
            pendingAction = .quit
            return .later
        }
        return continueQuit()
    }

    /// The running-runs step of quitting: `.now`, or hold the quit behind the "runs are still running" alert.
    func continueQuit() -> CloseRequestReply {
        switch quitDecision(runningCount: drivenRunning.count) {
        case .now: return .now
        case .ask(let message): quitMessage = message; quitPending = true; return .later
        }
    }

    /// Quit: suspends every running run (stopped, resumable on the next launch), then lets the app end.
    public func confirmQuit() async {
        let ids = drivenRunning.map(\.id)
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

/// Asks before ⌘Q or closing the window ends the app: about unsaved edits, then about running runs.
/// Both go through `AppModel.requestTerminate`; the answer goes to whichever request is pending.
@MainActor
public func installQuitHandling(on app: App, window: Window, model: AppModel) {
    model.replyToTerminate = { [weak app, weak window] answer in
        // A close and a ⌘Q can both be pending behind the one alert; each reply does nothing when its request
        // is not pending, so answering both answers each exactly once.
        window?.replyToCloseRequest(answer)
        app?.replyToTerminateRequest(answer)
    }
    app.onTerminateRequest = { model.requestTerminate() }
    window.onCloseRequest = { model.requestTerminate() }
}
