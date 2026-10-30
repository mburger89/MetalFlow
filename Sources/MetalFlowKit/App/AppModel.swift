import Foundation
import MetalFlowCore
import Observation

/// The two top-level screens.
public enum Screen: Sendable, Hashable {
    /// Runs, needs-you and activity.
    case dashboard
    /// The flow editor.
    case studio
}

/// Something the user has open and may dismiss.
public enum WorkingItem: Sendable, Hashable {
    /// A flow file open in the Studio.
    case flow(URL)
    /// A run open in its detail view.
    case run(RunID)
}

/// An inline banner message.
public struct Notice: Sendable, Equatable {
    /// How the banner looks.
    public enum Kind: Sendable, Equatable {
        /// An error.
        case error
        /// Information.
        case info
    }
    /// The text shown.
    public var text: String
    /// Error or info.
    public var kind: Kind
    /// Creates a notice.
    public init(_ text: String, kind: Kind = .error) {
        self.text = text
        self.kind = kind
    }
}

/// The app's state: every run, the derived dashboard lists, selection and the activity feed.
@Observable @MainActor
public final class AppModel {
    /// Every known run.
    public private(set) var runs: [RunID: Run] = [:]
    /// Run ids, newest first.
    public private(set) var order: [RunID] = []
    /// The visible screen.
    public var screen: Screen = .dashboard {
        didSet {
            if screen == .studio { ensureDraft() }
            if screen != oldValue { detailMayHaveOpened() }
        }
    }
    /// The flow open in the Studio, if any.
    public var draft: FlowDraft? {
        didSet {
            guard draft !== oldValue else { return }
            studioRun = nil
            draft?.onRetarget = { [weak self] in self?.studioRun = nil }
        }
    }
    /// The run overlaid on the Studio canvas; nil shows the definition only.
    public var studioRun: RunID?
    /// The issue typed in the Studio's launch field.
    public var studioIssue = ""
    /// The run shown in detail, if any.
    public var selectedRun: RunID? {
        didSet { if selectedRun != oldValue { detailMayHaveOpened() } }
    }
    /// The feed, newest first, at most `activityLimit` items.
    public private(set) var activity: [ActivityItem] = []
    /// Flows and runs the user has open.
    public internal(set) var workingOn: [WorkingItem] = []
    /// The banner, if any.
    public var notice: Notice?
    /// What the user asked for while the draft has unsaved edits; the Save / Discard / Cancel alert is up.
    public internal(set) var pendingAction: PendingAction?
    /// The flow the user asked to open while the draft has unsaved edits, if that is what is pending.
    public var pendingOpen: URL? {
        if case .open(let url) = pendingAction { return url }
        return nil
    }
    /// True while the Open Flow panel is showing.
    public internal(set) var isOpenFlowVisible = false
    /// True while the "runs are still running" quit alert is up.
    public internal(set) var quitPending = false
    /// Set by ⌘L; the launch bar's issue field takes focus and clears it.
    public var launchFocusRequested = false
    /// Brings the window forward. Called only in response to a notification click; the app sets it.
    public var activateApp: @MainActor () -> Void = {}
    /// Answers a pending termination request; the app sets it.
    public var replyToTerminate: @MainActor (Bool) -> Void = { _ in }
    /// Runs waiting for the user, newest first. Cached: updated by `apply`.
    public private(set) var needsYou: [Run] = []
    /// Runs being executed, newest first. Cached.
    public private(set) var running: [Run] = []
    /// Runs that are over, newest first. Cached.
    public private(set) var finished: [Run] = []

    /// The launch bar's selections and text.
    public var launchForm = LaunchForm()
    /// Repositories offered by the launch bar: the client's known repos plus ones added by path.
    public internal(set) var repos: [URL] = []
    /// The `.flow` files of the selected repo, cached when the repo changes.
    public internal(set) var repoFlows: [URL] = []
    /// Unsent answer text, keyed by `AppModel.draftKey(_:_:)`.
    public var answerDrafts: [String: String] = [:]
    /// True while a launch from the launch bar is in flight.
    public internal(set) var isLaunching = false
    var addedRepos: [URL] = []

    /// What the last pick of each lane showed, per run. Cleared for a lane when it is picked again.
    public internal(set) var pickOutcomes: [RunID: [LaneID: PickOutcome]] = [:]
    /// The run whose pick is in flight; every pick button is disabled meanwhile.
    public internal(set) var pickingRun: RunID?
    /// Branch-name drafts, keyed by `AppModel.laneKey(_:_:)`.
    public var branchDrafts: [String: String] = [:]
    /// The lanes whose "Branch from here" field is open, keyed by `AppModel.laneKey(_:_:)`.
    public var branchOpen: Set<String> = []
    /// The lane whose diff is open, if any.
    public internal(set) var openDiff: DiffKey?
    /// Parsed diffs by lane. Absent while loading.
    public internal(set) var diffChunks: [DiffKey: [AttributedString]] = [:]
    /// The run whose "Discard this run?" confirmation is up, if any.
    public var confirmingDiscard: RunID?
    var diffRevisions: [DiffKey: Int] = [:]
    var diffInFlight: Set<DiffKey> = []
    /// True once `start()` has restored the saved runs and made the first repo selection.
    public private(set) var isReady = false
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    /// The feed's capacity.
    public static let activityLimit = 200

    /// Incremented for every write to a bucket array; tests use it to prove `apply` is O(1) per update.
    var rebuildCount = 0
    private var started = false
    let notifyContinuation: AsyncStream<NotifyCommand>.Continuation
    /// The body last posted for each run in needs-you, so a changed reason re-posts and an unchanged one does not.
    var postedBodies: [RunID: String] = [:]
    /// True from the user's "Quit" until the app ends: no notifications fire for runs being suspended.
    var isQuitting = false
    /// The quit alert's text, fixed when it was raised.
    public internal(set) var quitMessage = ""

    let client: EngineClient
    let notifier: Notifier
    private let clock: @MainActor () -> Date
    /// The model's notion of now (injected in tests).
    public var now: Date { clock() }

    private enum Bucket { case needsYou, running, finished }

    /// Creates a model over a client.
    public init(client: EngineClient, notifier: Notifier, clock: @escaping @MainActor () -> Date = { Date() }) {
        self.client = client
        self.notifier = notifier
        self.clock = clock
        let (stream, continuation) = AsyncStream.makeStream(of: NotifyCommand.self, bufferingPolicy: .unbounded)
        notifyContinuation = continuation
        // The queue runs from creation, not from `start()`, so `flushNotifications()` always returns.
        Task { await Self.runNotifyQueue(stream, notifier: notifier) }
    }

    deinit { notifyContinuation.finish() }

    // MARK: - Updates

    /// Restores saved runs, then applies engine updates until the stream ends.
    public func start() async {
        guard !started else { return }
        started = true
        enqueue(.removeAll)
        await refreshRepos()
        do {
            for run in try await client.restore() { apply(run, restoring: true) }
        } catch {
            notice = Notice(error.localizedDescription)
        }
        if !needsYou.isEmpty { enqueue(.badge(needsYou.count)) }
        for run in needsYou { postedBodies[run.id] = Self.notificationBody(for: run) }
        isReady = true
        // Clicks that arrived before launch finished are buffered; only now can they find their run.
        let clicks = Task { await runClicks() }
        defer { clicks.cancel() }
        for waiter in readyWaiters { waiter.resume() }
        readyWaiters = []
        for await run in client.updates { apply(run) }
    }

    /// Returns once `start()` has restored the saved runs and scanned the first repo.
    public func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    /// Takes a snapshot of a run: stale ones (revision not above the stored one) are ignored.
    public func apply(_ run: Run) { apply(run, restoring: false) }

    private func apply(_ run: Run, restoring: Bool) {
        let old = runs[run.id]
        if let old, run.revision <= old.revision { return }
        runs[run.id] = run

        if old == nil {
            insertID(run)
        }
        if old != nil { dropStaleDiffs(of: run.id) }
        let before = old.map(bucket(of:))
        let after = bucket(of: run)
        if before == after {
            replace(run, in: after)
        } else {
            if let before { remove(run.id, from: before) }
            insert(run, into: after)
        }
        if !restoring {
            if before != after {
                notifyTransition(run, enteredNeedsYou: after == .needsYou, leftNeedsYou: before == .needsYou)
            } else if after == .needsYou {
                notifyReasonChange(run)
            }
        }

        if !restoring {
            let items = deriveActivity(old: old, new: run, now: clock())
            if !items.isEmpty {
                activity.insert(contentsOf: items.reversed(), at: 0)
                if activity.count > Self.activityLimit { activity.removeLast(activity.count - Self.activityLimit) }
            }
        }
    }

    private func bucket(of run: Run) -> Bucket {
        switch run.status {
        case .needsYou: .needsYou
        case .running: .running
        case .failed:
            // A failed node can be retried, so such a run waits for the user instead of being history.
            run.nodes.values.contains { if case .failed = $0.state { true } else { false } } ? .needsYou : .finished
        case .merged, .discarded, .cancelled, .completed: .finished
        }
    }

    /// Inserts into `order`, newest first (ties by id, as the store sorts).
    private func insertID(_ run: Run) {
        let index = order.firstIndex { other in
            guard let o = runs[other] else { return false }
            return isNewer(run, than: o)
        } ?? order.count
        order.insert(run.id, at: index)
    }

    private func isNewer(_ a: Run, than b: Run) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id.rawValue < b.id.rawValue
    }

    private func mutate(_ bucket: Bucket, _ body: (inout [Run]) -> Void) {
        rebuildCount += 1
        switch bucket {
        case .needsYou: body(&needsYou)
        case .running: body(&running)
        case .finished: body(&finished)
        }
    }

    private func replace(_ run: Run, in bucket: Bucket) {
        mutate(bucket) { list in
            if let i = list.firstIndex(where: { $0.id == run.id }) {
                list[i] = run
            } else {
                assertionFailure("run \(run.id) missing from its bucket")
                list.insert(run, at: list.firstIndex { self.isNewer(run, than: $0) } ?? list.count)
            }
        }
    }

    private func remove(_ id: RunID, from bucket: Bucket) {
        mutate(bucket) { $0.removeAll { $0.id == id } }
    }

    private func insert(_ run: Run, into bucket: Bucket) {
        mutate(bucket) { list in
            let i = list.firstIndex { isNewer(run, than: $0) } ?? list.count
            list.insert(run, at: i)
        }
    }

    // MARK: - Working set

    /// Opens a run in detail and remembers it in `workingOn`.
    public func open(run id: RunID) {
        selectedRun = id
        if !workingOn.contains(.run(id)) { workingOn.append(.run(id)) }
    }

    /// Remembers an open flow, loads it into the Studio and shows the Studio. A flow that is already the
    /// draft keeps its draft. A load error becomes a notice and the screen stays.
    public func open(flow url: URL) {
        if let draft, draft.isDirty, draft.url != url {
            pendingAction = .open(url)
            return
        }
        openWithoutAsking(url)
    }

    func openWithoutAsking(_ url: URL) {
        if !workingOn.contains(.flow(url)) { workingOn.append(.flow(url)) }
        loadDraft(from: url)
    }

    /// Removes an item from `workingOn`, closing the detail if it was showing that run.
    public func dismiss(_ item: WorkingItem) {
        workingOn.removeAll { $0 == item }
        if case .run(let id) = item, selectedRun == id { selectedRun = nil }
    }

    // MARK: - Actions

    /// Starts a run. Returns its id, or nil with a notice.
    @discardableResult
    public func launch(flow: Flow, repo: URL, input: String) async -> RunID? {
        do { return try await client.launch(flow: flow, repo: repo, input: input) } catch { fail(error); return nil }
    }

    /// Answers a node's question.
    public func answer(_ id: RunID, node: NodeKey, reply: String, allowTools: [String] = []) async {
        await perform { try await self.client.answer(id, node: node, reply: reply, allowTools: allowTools) }
    }

    /// Resumes a cut-short run.
    public func resume(_ id: RunID) async {
        await perform { try await self.client.resumeInterrupted(id) }
    }

    /// Re-runs a failed node.
    public func retry(_ id: RunID, node: NodeKey) async {
        await perform { try await self.client.retry(id, node: node) }
    }

    /// Cancels a run.
    public func cancel(_ id: RunID) async {
        await client.cancel(id)
    }

    /// Merges a lane and records the outcome for its card. Only an explicit click calls this. A second call
    /// while a pick is in flight does nothing. A merge returns to the dashboard.
    @discardableResult
    public func pick(_ id: RunID, lane: LaneID) async -> MergeResult? {
        guard pickingRun == nil else { return nil }
        pickingRun = id
        defer { pickingRun = nil }
        pickOutcomes[id, default: [:]][lane] = nil
        do {
            let result = try await client.pick(id, lane: lane)
            let outcome: PickOutcome
            switch result {
            case .merged: outcome = .merged
            case .blockedDirty(let checkout): outcome = .blockedDirty(checkout)
            case .conflict(let files): outcome = .conflict(files)
            }
            pickOutcomes[id, default: [:]][lane] = outcome
            if outcome == .merged, selectedRun == id { selectedRun = nil }
            return result
        } catch {
            pickOutcomes[id, default: [:]][lane] = .failed(error.localizedDescription)
            return nil
        }
    }

    /// Discards a run. On success the detail closes.
    @discardableResult
    public func discard(_ id: RunID) async -> Bool {
        let ok = await perform { try await self.client.discard(id) }
        if ok, selectedRun == id { selectedRun = nil }
        return ok
    }

    /// Keeps a lane's branch under `name`.
    @discardableResult
    public func branchFromHere(_ id: RunID, lane: LaneID, name: String) async -> Bool {
        await perform { try await self.client.branchFromHere(id, lane: lane, name: name) }
    }

    @discardableResult
    private func perform(_ body: () async throws -> Void) async -> Bool {
        do { try await body(); return true } catch { fail(error); return false }
    }

    private func fail(_ error: Error) {
        notice = Notice(error.localizedDescription)
    }
}
