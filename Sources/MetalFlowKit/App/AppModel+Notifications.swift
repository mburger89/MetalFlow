import Foundation
import MetalFlowCore

/// What the model asks its notifier to do, in order.
enum NotifyCommand: Sendable {
    case post(id: String, title: String, body: String)
    case remove(String)
    case removeAll
    case badge(Int)
    case barrier(CheckedContinuation<Void, Never>)
}

extension AppModel {
    /// Returns once every notifier call queued so far has finished.
    public func flushNotifications() async {
        await withCheckedContinuation { notifyContinuation.yield(.barrier($0)) }
    }

    /// Consumes the notifier queue in order.
    nonisolated static func runNotifyQueue(_ stream: AsyncStream<NotifyCommand>, notifier: Notifier) async {
        for await command in stream {
            switch command {
            case .removeAll: await notifier.removeAll()
            case .post(let id, let title, let body): await notifier.post(id: id, title: title, body: body)
            case .remove(let id): await notifier.remove(id: id)
            case .badge(let n): await notifier.setBadge(n)
            case .barrier(let c): c.resume()
            }
        }
    }

    /// Opens the run behind a clicked notification and brings the window forward. The only caller of
    /// `activateApp`.
    func runClicks() async {
        for await id in notifier.clicks {
            let run = RunID(rawValue: id)
            guard runs[run] != nil else { continue }
            // The user wants this run: nothing they had half-started may cover it or pull them away later.
            hideOpenFlow()
            cancelPending()
            screen = .dashboard
            open(run: run)
            activateApp()
        }
    }

    func enqueue(_ command: NotifyCommand) { notifyContinuation.yield(command) }

    /// Posts, removes and badges for a run that moved between buckets in a live update.
    func notifyTransition(_ run: Run, enteredNeedsYou: Bool, leftNeedsYou: Bool) {
        if enteredNeedsYou {
            let body = Self.notificationBody(for: run)
            postedBodies[run.id] = body
            post(run, body: body)
        }
        if leftNeedsYou {
            postedBodies[run.id] = nil
            enqueue(.remove(run.id.rawValue))
        }
        if enteredNeedsYou || leftNeedsYou { enqueue(.badge(needsYou.count)) }
    }

    /// A run that stays in needs-you with a different reason posts again under the same id.
    func notifyReasonChange(_ run: Run) {
        let body = Self.notificationBody(for: run)
        guard postedBodies[run.id] != body else { return }
        postedBodies[run.id] = body
        post(run, body: body)
    }

    private func post(_ run: Run, body: String) {
        guard !isQuitting, !(selectedRun == run.id && screen == .dashboard) else { return }
        enqueue(.post(id: run.id.rawValue, title: run.title, body: body))
    }

    /// Called when the run detail becomes visible: the notification has done its job.
    func detailMayHaveOpened() {
        if screen == .dashboard, let id = selectedRun, runs[id] != nil { enqueue(.remove(id.rawValue)) }
    }

    /// The notification text for a run: what the run waits on (its first `needsYou` entry, in plan order), else an
    /// interrupted node; a failed node only names the reason when the run itself failed (or nothing else applies).
    public static func notificationBody(for run: Run) -> String {
        func title(_ key: NodeKey) -> String { run.flow.node(key.node)?.title ?? key.node.rawValue }
        let keys = run.orderedNodeKeys
        func state(where match: (NodeState) -> Bool) -> NodeKey? { keys.first { run.nodes[$0].map { match($0.state) } ?? false } }
        let failedKey = state { $0.isFailed }
        if case .failed = run.status, let key = failedKey { return "\(title(key)) failed — retry when ready" }
        if let (key, reason) = run.needsYou.first {
            switch reason {
            case .pickWinner(_, true): return "Gate failed on every candidate"
            case .pickWinner(let r, false): return r.map { "Judge recommends \($0) — pick a candidate" } ?? "Pick a candidate"
            case .question(let q):
                let line = q.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                return "\(title(key)) asks: \(String(line.prefix(120)))"
            case .deniedTools(let tools): return "\(title(key)) needs permission: \(tools.joined(separator: ", "))"
            }
        }
        if state(where: { $0 == .interrupted }) != nil { return "Interrupted — resume when ready" }
        if let key = failedKey { return "\(title(key)) failed — retry when ready" }
        return "Needs your attention"
    }
}
