import Foundation
import MetalFlowCore

/// What the model asks its notifier to do, in order.
enum NotifyCommand: Sendable {
    case post(id: String, title: String, body: String)
    case remove(String)
    case badge(Int)
    case barrier(CheckedContinuation<Void, Never>)
}

extension AppModel {
    /// Returns once every notifier call queued so far has finished.
    public func flushNotifications() async {
        await withCheckedContinuation { notifyContinuation.yield(.barrier($0)) }
    }

    /// Consumes the notifier queue in order. Started by `start()`.
    func runNotifyQueue() async {
        for await command in notifyStream {
            switch command {
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
            screen = .dashboard
            open(run: run)
            activateApp()
        }
    }

    func enqueue(_ command: NotifyCommand) { notifyContinuation.yield(command) }

    /// Posts, removes and badges for a run that moved between buckets in a live update.
    func notifyTransition(_ run: Run, enteredNeedsYou: Bool, leftNeedsYou: Bool) {
        if enteredNeedsYou, !(selectedRun == run.id && screen == .dashboard) {
            enqueue(.post(id: run.id.rawValue, title: run.title, body: Self.notificationBody(for: run)))
        }
        if leftNeedsYou { enqueue(.remove(run.id.rawValue)) }
        if enteredNeedsYou || leftNeedsYou { enqueue(.badge(needsYou.count)) }
    }

    /// Called when the run detail becomes visible: the notification has done its job.
    func detailMayHaveOpened() {
        if screen == .dashboard, let id = selectedRun, runs[id] != nil { enqueue(.remove(id.rawValue)) }
    }

    /// The notification text for a run: the first thing that waits on the user, in plan order.
    public static func notificationBody(for run: Run) -> String {
        let order = run.flow.nodes.map(\.id)
        let keys = run.nodes.keys.sorted {
            let (i, j) = (order.firstIndex(of: $0.node) ?? Int.max, order.firstIndex(of: $1.node) ?? Int.max)
            return i != j ? i < j : ($0.lane ?? "") < ($1.lane ?? "")
        }
        for key in keys {
            guard let state = run.nodes[key]?.state else { continue }
            let title = run.flow.node(key.node)?.title ?? key.node.rawValue
            switch state {
            case .needsYou(.pickWinner(_, true)): return "Gate failed on every candidate"
            case .needsYou(.pickWinner(let r, false)):
                return r.map { "Judge recommends \($0) — pick a candidate" } ?? "Pick a candidate"
            case .needsYou(.question(let q)):
                let line = q.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                return "\(title) asks: \(String(line.prefix(120)))"
            case .needsYou(.deniedTools(let tools)): return "\(title) needs permission: \(tools.joined(separator: ", "))"
            case .interrupted: return "Interrupted — resume when ready"
            case .failed: return "\(title) failed — retry when ready"
            case .waiting, .running, .succeeded, .cancelled: continue
            }
        }
        return "Needs your attention"
    }
}
