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
            if oldValue == .studio, screen != .studio { draft?.leaveStudio() }
            if screen == .studio { ensureDraft() }
            if screen != oldValue { detailMayHaveOpened() }
        }
    }
    /// The flow open in the Studio, if any.
    public var draft: FlowDraft? {
        didSet {
            guard draft !== oldValue else { return }
            oldValue?.leaveStudio()
            studioRun = nil
            studioValues = [:]
        }
    }
    /// The run overlaid on the Studio canvas; nil shows the definition only.
    public var studioRun: RunID?
    /// What was typed in the Studio's launch row, by field name.
    public var studioValues: [String: String] = [:]
    /// True while the save-destination panel is showing.
    public internal(set) var isSavePanelVisible = false
    /// What the destination panel is for: a first save, or a copy that leaves out the flow's current location.
    public internal(set) var savePanelMode = SavePanelMode.save
    /// Non-nil while the folder dialog is up.
    public internal(set) var addRepoRequest: AddRepoPurpose?
    /// The purpose of a dialog that has just ended, until its result (or its cancel) is handled.
    var addRepoClaim: AddRepoPurpose?
    /// The save waiting for the destination panel's answer.
    var saveDestinationWaiter: CheckedContinuation<SaveDestination?, Never>?
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
    /// The flow the user asked to open while the draft has unsaved edits, if that is what is pending (tests).
    var pendingOpen: URL? {
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
    /// Opens a URL in the user's browser. The app sets it to `NSWorkspace.shared.open`; tests record it.
    public var openURL: @MainActor (URL) -> Void = { _ in }
    /// Answers a pending termination request; the app sets it.
    public var replyToTerminate: @MainActor (Bool) -> Void = { _ in }
    /// Runs waiting for the user, newest first. Cached: updated by `apply`.
    public private(set) var needsYou: [Run] = []
    /// Runs being executed, newest first. Cached.
    public private(set) var running: [Run] = []
    /// Runs that are over, newest first. Cached.
    public private(set) var finished: [Run] = []
    /// Running runs whose lock another process (an `mflow` command) holds. This app does not drive them: it
    /// cannot cancel or suspend them and receives no updates from them, so `refreshElsewhere()` polls their saved state.
    /// Cleared for a run once its lock is released or an update from this app's engine arrives.
    public internal(set) var runningElsewhere: Set<RunID> = []
    /// Running runs this app drives: what quitting would stop.
    public var drivenRunning: [Run] { running.filter { !runningElsewhere.contains($0.id) } }

    /// The launch bar's selections and text.
    public var launchForm = LaunchForm()
    /// Repositories offered by the launch bar: the client's known repos plus ones added by path.
    public internal(set) var repos: [URL] = []
    /// Every flow the app can open: built-ins, the library, then each known repo's `.flows`. Refreshed on start,
    /// after "Add repo..." and after a save.
    public internal(set) var catalog: [FlowEntry] = []
    /// The repo that seeds the launch form's exposed repo field: the first known repo, or the last one added.
    public internal(set) var selectedRepo: URL?
    /// The selected flow's launch fields, in order; empty when the flow cannot be launched.
    public internal(set) var launchFields: [LaunchField] = []
    /// Why the selected flow cannot be launched, in the spec's wording.
    public internal(set) var launchError: String?
    /// True while the selected flow is being read; Launch stays disabled meanwhile.
    public internal(set) var isLoadingLaunch = false
    /// The flow `launchFields` was derived from.
    var launchFlow: Flow?
    var launchGeneration = 0
    /// Bumped by every catalog refresh, so an older scan finishing late is dropped.
    var catalogGeneration = 0
    /// The repo folder name shown for a flow whose Repo node is This repo or Fixed.
    public internal(set) var launchResolvedRepo: String?
    /// Unsent answer text, keyed by `AppModel.draftKey(_:_:)`.
    public var answerDrafts: [String: String] = [:]
    /// Unsent follow-up text, keyed by `AppModel.draftKey(_:_:)`. Closing the box keeps it.
    public var followUpDrafts: [String: String] = [:]
    /// The steps whose follow-up box is open, keyed by `AppModel.draftKey(_:_:)`.
    public var followingUp: Set<String> = []
    /// The steps whose follow-up is being sent, keyed like `followUpDrafts`. Send is refused and disabled meanwhile.
    public internal(set) var followUpSending: Set<String> = []
    /// True while a launch from the launch bar is in flight.
    public internal(set) var isLaunching = false
    var addedRepos: [URL] = []
    /// How many agent sessions may run at once. Changed through `setMaxSessions`.
    public private(set) var maxSessions = RunSettings.defaultMaxSessions
    /// The limit last saved, which `maxSessions` returns to when a save fails.
    private(set) var savedMaxSessions = RunSettings.defaultMaxSessions
    /// The newest value asked for that no save has taken yet.
    private var pendingMaxSessions: Int?
    /// The running save loop; nil when idle.
    private var maxSessionsSaves: Task<Void, Never>?

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
    /// Diffs whose run changed while they were loading: the load repeats once more when it ends.
    var diffReloadWanted: Set<DiffKey> = []
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
    private let pause: @Sendable () async -> Void
    /// The model's notion of now (injected in tests).
    public var now: Date { clock() }

    private enum Bucket { case needsYou, running, finished }

    /// Creates a model over a client. `pause` is the wait between polls of runs another process drives.
    public init(client: EngineClient, notifier: Notifier, clock: @escaping @MainActor () -> Date = { Date() },
                pause: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(2)) }) {
        self.client = client
        self.notifier = notifier
        self.clock = clock
        self.pause = pause
        let (stream, continuation) = AsyncStream.makeStream(of: NotifyCommand.self, bufferingPolicy: .unbounded)
        notifyContinuation = continuation
        // The queue runs from creation, not from `start()`, so `flushNotifications()` always returns.
        Task { await Self.runNotifyQueue(stream, notifier: notifier) }
    }

    deinit { notifyContinuation.finish() }

    // MARK: - Updates

    /// One pass over the runs another process drives: shows the progress it saved, and forgets the runs whose lock it
    /// released.
    public func refreshElsewhere() async {
        for id in runningElsewhere.sorted(by: { $0.rawValue < $1.rawValue }) {
            // A run left running after its process released the lock was cut short; its saved state stands.
            if let run = await client.reload(id) { apply(run, restoring: false, fromElsewhere: true) }
            if !(await client.isRunningElsewhere(id)) { runningElsewhere.remove(id) }
        }
    }

    /// Adds the runs another process started since the app last looked, and forgets the ones it deleted.
    public func discoverRuns() async {
        let discovery = await client.discover()
        for run in discovery.found where runs[run.id] == nil {
            if run.status == .running, await client.isRunningElsewhere(run.id) { runningElsewhere.insert(run.id) }
            apply(run, restoring: false, fromElsewhere: true)
        }
        for id in discovery.vanished { forget(id) }
    }

    /// Removes a run another process deleted: from the lists, the working set, the notification and badge, and the
    /// caches. Its open detail closes with a notice.
    private func forget(_ id: RunID) {
        guard let run = runs[id] else { return }
        let wasNeedsYou = bucket(of: run) == .needsYou
        remove(id, from: bucket(of: run))
        runs[id] = nil
        order.removeAll { $0 == id }
        runningElsewhere.remove(id)
        workingOn.removeAll { $0 == .run(id) }
        pickOutcomes[id] = nil
        for key in diffChunks.keys where key.run == id { diffChunks[key] = nil }
        for key in diffRevisions.keys where key.run == id { diffRevisions[key] = nil }
        if openDiff?.run == id { openDiff = nil }
        if studioRun == id { studioRun = nil }
        if confirmingDiscard == id { confirmingDiscard = nil }
        postedBodies[id] = nil
        if wasNeedsYou {
            enqueue(.remove(id.rawValue))
            enqueue(.badge(needsYou.count))
        }
        if selectedRun == id {
            selectedRun = nil
            screen = .dashboard
            notice = Notice("This run was discarded elsewhere.")
        }
    }

    /// Every `pause`, until cancelled: discovers new runs, and re-reads the ones other processes drive.
    private func pollElsewhere() async {
        while !Task.isCancelled {
            await pause()
            if Task.isCancelled { return }
            await discoverRuns()
            if !runningElsewhere.isEmpty { await refreshElsewhere() }
        }
    }

    /// Restores saved runs, then applies engine updates until the stream ends.
    public func start() async {
        guard !started else { return }
        started = true
        enqueue(.removeAll)
        savedMaxSessions = client.maxSessions()
        maxSessions = savedMaxSessions
        await refreshRepos()
        do {
            for run in try await client.restore() { apply(run, restoring: true) }
        } catch {
            notice = Notice(error.localizedDescription)
        }
        for run in running where await client.isRunningElsewhere(run.id) { runningElsewhere.insert(run.id) }
        if !needsYou.isEmpty { enqueue(.badge(needsYou.count)) }
        for run in needsYou { postedBodies[run.id] = Self.notificationBody(for: run) }
        isReady = true
        // Clicks that arrived before launch finished are buffered; only now can they find their run.
        let clicks = Task { await runClicks() }
        let polling = Task { await pollElsewhere() }
        defer { clicks.cancel(); polling.cancel() }
        for waiter in readyWaiters { waiter.resume() }
        readyWaiters = []
        for await run in client.updates { apply(run) }
    }

    /// Returns once `start()` has restored the saved runs and scanned the first repo. Tests only: it never returns
    /// if `start()` is never called.
    func waitUntilReady() async {
        if isReady { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    /// Takes a snapshot of a run: stale ones (revision not above the stored one) are ignored.
    public func apply(_ run: Run) { apply(run, restoring: false) }

    /// `fromElsewhere`: the snapshot is another process's saved state, so the run stays in `runningElsewhere`.
    private func apply(_ run: Run, restoring: Bool, fromElsewhere: Bool = false) {
        let old = runs[run.id]
        if let old, run.revision <= old.revision { return }
        runs[run.id] = run
        // A box left open on a step that can no longer take a follow-up closes (its draft stays).
        for key in run.nodes.keys where !run.canFollowUp(key) {
            followingUp.remove(Self.draftKey(run.id, key))
        }
        // An update means this app's engine is driving the run now.
        if !restoring && !fromElsewhere { runningElsewhere.remove(run.id) }

        if old == nil {
            insertID(run)
        }
        if old != nil {
            dropStaleDiffs(of: run.id)
            if !restoring { reloadOpenDiff(of: run) }
        }
        let before = old.map(bucket(of:))
        let after = bucket(of: run)
        if before == after {
            replace(run, in: after)
        } else {
            if let before { remove(run.id, from: before) }
            insert(run, into: after)
        }
        if !restoring, old != nil, case .prOpened(_, let url) = run.status, old?.status != run.status {
            notice = Notice("Opened \(url)", kind: .info)
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
            run.hasFailedNode ? .needsYou : .finished
        case .merged, .prOpened, .discarded, .cancelled, .completed: .finished
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
        commitStudioEdit()
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
    public func launch(flow: Flow, location: FlowLocation, values: [String: String]) async -> RunID? {
        do { return try await client.launch(flow: flow, location: location, values: values) } catch {
            switch error as? RunEngineError {
            case .launch(let e)?: notice = Notice(flow.message(for: e))
            case .invalid(let e)?: notice = Notice(flow.message(for: e))
            default: fail(error)
            }
            return nil
        }
    }

    /// Answers a node's question. Returns false (with a notice) when the engine refuses.
    @discardableResult
    public func answer(_ id: RunID, node: NodeKey, reply: String, allowTools: [String] = []) async -> Bool {
        await perform { try await self.client.answer(id, node: node, reply: reply, allowTools: allowTools) }
    }

    /// Allows the tools a node was denied and lets it carry on. The one reply both screens send.
    @discardableResult
    public func allowAndContinue(run id: RunID, node: NodeKey, tools: [String]) async -> Bool {
        await answer(id, node: node, reply: "Continue.", allowTools: tools)
    }

    /// Sends the reply drafted for a node's question. The draft is cleared only once the engine accepts it, and
    /// only if the user has not typed something else meanwhile. Does nothing for an empty reply.
    @discardableResult
    public func sendAnswer(run id: RunID, node: NodeKey) async -> Bool {
        let key = Self.draftKey(id, node)
        let typed = answerDrafts[key] ?? ""
        let reply = Self.trimmed(typed)
        guard !reply.isEmpty else { return false }
        guard await answer(id, node: node, reply: reply) else { return false }
        if answerDrafts[key] == typed { answerDrafts[key] = nil }
        return true
    }

    /// Opens or closes a step's follow-up box. Closing keeps the draft.
    public func toggleFollowUp(run id: RunID, node: NodeKey) {
        let key = Self.draftKey(id, node)
        if followingUp.contains(key) { followingUp.remove(key) } else { followingUp.insert(key) }
    }

    /// Sends the follow-up drafted for a step. The box closes and the draft clears only once the engine accepts it,
    /// and the draft only if the user has not typed something else meanwhile. Does nothing for an empty message.
    @discardableResult
    public func sendFollowUp(run id: RunID, node: NodeKey) async -> Bool {
        let key = Self.draftKey(id, node)
        let typed = followUpDrafts[key] ?? ""
        let message = Self.trimmed(typed)
        guard !message.isEmpty, !followUpSending.contains(key) else { return false }
        followUpSending.insert(key)
        defer { followUpSending.remove(key) }
        guard await perform({ try await self.client.followUp(id, node: node, message: message) }) else { return false }
        if followUpDrafts[key] == typed { followUpDrafts[key] = nil }
        followingUp.remove(key)
        return true
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
            case .handedToPullRequest:
                outcome = .openingPullRequest
                notice = Notice("Opening pull request\u{2026}", kind: .info)
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

    /// Shows a new session limit at once and saves it. One save runs at a time; while it runs, newer values replace
    /// the pending one, so the latest value is the one that lands and in-between ones may be skipped. A failed save
    /// shows a notice and, unless a newer value is pending, returns the display to the saved limit.
    public func changeMaxSessions(_ value: Int) {
        let value = RunSettings.clamped(value)
        maxSessions = value
        pendingMaxSessions = value
        if maxSessionsSaves == nil { maxSessionsSaves = Task { await self.saveMaxSessionsLoop() } }
    }

    /// `changeMaxSessions`, returning once every save it started has finished.
    public func setMaxSessions(_ max: Int) async {
        changeMaxSessions(max)
        await waitForMaxSessionsSaved()
    }

    /// Returns once no save is running or pending.
    func waitForMaxSessionsSaved() async {
        while let saves = maxSessionsSaves { await saves.value }
    }

    private func saveMaxSessionsLoop() async {
        while let value = pendingMaxSessions {
            pendingMaxSessions = nil
            if value == savedMaxSessions { continue }
            if await perform({ try await self.client.setMaxSessions(value) }) {
                savedMaxSessions = value
            } else if pendingMaxSessions == nil {
                maxSessions = savedMaxSessions
            }
        }
        maxSessionsSaves = nil
    }

    @discardableResult
    private func perform(_ body: () async throws -> Void) async -> Bool {
        do { try await body(); return true } catch { fail(error); return false }
    }

    private func fail(_ error: Error) {
        notice = Notice(error.localizedDescription)
    }
}
