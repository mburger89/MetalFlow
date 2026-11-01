import Foundation
import MetalFlowCore

/// One line of the dashboard's activity feed.
public struct ActivityItem: Identifiable, Equatable, Sendable {
    /// What an item means, which colours it and decides whether it is urgent.
    public enum Kind: Sendable, Equatable {
        /// Neutral progress.
        case info
        /// A run needs the user.
        case needsYou
        /// Something finished well.
        case ok
        /// Something failed.
        case bad
    }

    /// Unique id of the item.
    public let id = UUID()
    /// When it was derived.
    public var time: Date
    /// The run it belongs to.
    public var runID: RunID
    /// The run's title at that moment.
    public var runTitle: String
    /// The line shown.
    public var text: String
    /// The item's meaning.
    public var kind: Kind

    /// Creates an item.
    public init(time: Date, runID: RunID, runTitle: String, text: String, kind: Kind) {
        self.time = time
        self.runID = runID
        self.runTitle = runTitle
        self.text = text
        self.kind = kind
    }

    public static func == (a: ActivityItem, b: ActivityItem) -> Bool {
        a.id == b.id
    }
}

/// Derives feed items from the difference between two snapshots of one run, oldest first.
/// `old == nil` means the run was just launched (only then is "started" reported).
func deriveActivity(old: Run?, new: Run, now: Date) -> [ActivityItem] {
    var items: [ActivityItem] = []
    func add(_ text: String, _ kind: ActivityItem.Kind) {
        items.append(ActivityItem(time: now, runID: new.id, runTitle: new.title, text: text, kind: kind))
    }
    if old == nil { add("started", .info) }

    let keys = new.orderedNodeKeys
    var gateFailed = false
    for key in keys {
        guard let node = new.nodes[key] else { continue }
        let before = old?.nodes[key]
        let isGate: Bool = {
            if case .gate? = new.flow.node(key.node)?.kind { return true }
            return false
        }()
        if node.state != before?.state {
            switch node.state {
            case .needsYou(.pickWinner(let recommended, let allFailed)):
                if allFailed {
                    add("all candidates failed the gate — waiting on you", .needsYou)
                } else if let recommended {
                    add("judge recommends \(recommended) — waiting on you", .needsYou)
                } else {
                    add("candidates ready — waiting on you", .needsYou)
                }
            case .needsYou(.question(let q)):
                add("asks: \(clipped(q))", .needsYou)
            case .needsYou(.deniedTools(let tools)):
                add("needs approval for \(tools.joined(separator: ", "))", .needsYou)
            case .failed(let message):
                if isGate { gateFailed = true } else { add("\(key) \(NodeStateStyle(.failed(message)).label.lowercased()): \(clipped(message))", .bad) }
            case .interrupted:
                add("\(key) \(NodeStateStyle(.interrupted).label.lowercased())", .info)
            case .running:
                if let line = node.log.last, line != before?.log.last { add(describeLogLine(line), .info) }
            case .waiting, .succeeded, .cancelled:
                break
            }
        } else if node.state == .running, let line = node.log.last, line != before?.log.last {
            add(describeLogLine(line), .info)
        }
    }
    if gateFailed {
        let gates = new.nodes.filter { key, _ in
            if case .gate? = new.flow.node(key.node)?.kind { return true }
            return false
        }
        let failed = gates.values.filter { $0.state.isFailed }.count
        add("gate failed on \(failed) of \(gates.count) candidate\(gates.count == 1 ? "" : "s")", .bad)
    }

    if let before = old, before.status != new.status {
        switch new.status {
        case .merged(let lane): add("merged candidate \(lane)", .ok)
        case .prOpened(let lane, let url): add("opened a pull request for candidate \(lane): \(url)", .ok)
        case .completed: add("completed", .ok)
        case .failed(let message): add("failed: \(clipped(message))", .bad)
        case .cancelled: add("cancelled", .info)
        case .discarded: add("discarded", .info)
        case .running, .needsYou: break
        }
    }
    return items
}

private func clipped(_ text: String, limit: Int = 80) -> String {
    let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? text
    return line.count > limit ? String(line.prefix(limit)) + "…" : line
}

/// "▸ Edit Foo.swift" becomes "edited Foo.swift"; other tool lines lose their marker.
private func describeLogLine(_ line: String) -> String {
    var text = line
    if text.hasPrefix("▸ ") { text.removeFirst(2) }
    if text.hasPrefix("Edit ") { return clipped("edited " + text.dropFirst(5)) }
    if text.hasPrefix("Write ") { return clipped("wrote " + text.dropFirst(6)) }
    return clipped(text)
}
