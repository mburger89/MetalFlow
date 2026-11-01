import Foundation
import MetalFlowCore
import MetalUI
import MetalUITesting
import Testing
@testable import MetalFlowKit

@MainActor
@Suite struct DashboardTests {
    let repo = URL(fileURLWithPath: "/repo")
    let flowFile = URL(fileURLWithPath: "/repo/.metalflow/Fix GitHub issue.flow")

    func fixture(_ runs: [Run] = [], gitRepos: Set<String> = []) async throws -> (AppModel, FakeEngineClient, TestWindow) {
        let client = FakeEngineClient(restored: runs, repos: [repo], flowFiles: [flowFile], gitRepoPaths: gitRepos)
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        try await window.runUntilIdle()
        return (model, client, window)
    }

    func press(_ id: String, in window: TestWindow) async throws {
        try window.click(window.element(identifier: id))
        try await window.runUntilIdle()
    }

    let builtinID = "builtin:Fix GitHub issue"

    @Test func staleCatalogScanIsDropped() async throws {
        let (model, client, _) = try await fixture()
        let old = client.catalog.entries
        client.catalog.holdNextScan()
        let first = Task { await model.refreshCatalog() }
        await client.catalog.waitForHeldScan()
        // A newer refresh starts and finishes while the first scan is still running.
        let extra = FlowEntry(id: "/repo/.flows/new.flow", name: "new", location: .of(file: URL(fileURLWithPath: "/repo/.flows/new.flow")),
                              file: URL(fileURLWithPath: "/repo/.flows/new.flow"))
        client.catalog.entries = old + [extra]
        await model.refreshCatalog()
        #expect(model.catalog.map(\.id) == old.map(\.id) + [extra.id])
        client.catalog.release()
        await first.value
        #expect(model.catalog.map(\.id) == old.map(\.id) + [extra.id], "the older scan must not overwrite the newer one")
    }

    /// A fixture whose catalog and flow files are scripted: built-in first, then `extra` entries (loaded from `flows`).
    func catalogFixture(repos: [URL]? = nil, extra: [(FlowEntry, Flow)] = [], gitRepos: Set<String> = []) async throws
        -> (AppModel, FakeEngineClient, TestWindow) {
        let client = FakeEngineClient(repos: repos ?? [repo], gitRepoPaths: gitRepos)
        client.catalog.entries += extra.map(\.0)
        for (entry, flow) in extra { if let file = entry.file { client.files.flows[file] = flow } }
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        try await window.runUntilIdle()
        return (model, client, window)
    }

    func repoNodeFlow(_ name: String, mode: RepoMode) -> Flow {
        var flow = BuiltinFlows.fixGitHubIssue
        flow.name = name
        for i in flow.nodes.indices {
            if case .repo = flow.nodes[i].kind { flow.nodes[i].kind = .repo(RepoConfig(mode: mode)) }
        }
        return flow
    }

    func entry(_ file: String, _ name: String) -> FlowEntry {
        let url = URL(fileURLWithPath: file)
        return FlowEntry(id: url.path, name: name, location: .of(file: url), file: url)
    }

    func type(_ text: String, into id: String, in window: TestWindow) async throws {
        try window.click(window.element(identifier: id))
        window.typeText(text)
        try await window.runUntilIdle()
    }

    @Test func launchBarListsCatalog() async throws {
        let lib = entry("/lib/flows/Triage.flow", "Triage")
        let inRepo = entry("/repo/.flows/Ship.flow", "Ship")
        let (model, _, window) = try await catalogFixture(extra: [
            (lib, repoNodeFlow("Triage", mode: .exposed(default: nil))),
            (inRepo, repoNodeFlow("Ship", mode: .thisRepo))])
        try window.click(window.element(identifier: "launch.flow"))
        let menu = try #require(window.presentedMenu)
        #expect(menu.items.map(\.title) == ["Fix GitHub issue \u{2014} Built-in", "Triage \u{2014} Library", "Ship \u{2014} repo"])
        try window.chooseMenuItem("Triage \u{2014} Library")
        try await window.runUntilIdle()
        #expect(model.launchForm.flow == lib.id)
        try window.click(window.element(identifier: "launch.flow"))
        #expect(window.presentedMenu?.items.first { $0.isOn }?.title == "Triage \u{2014} Library")
        try window.dismissMenu()
    }

    @Test func builtinShowsIssueAndRepoFields() async throws {
        let (model, _, window) = try await catalogFixture()
        #expect(model.launchForm.flow == builtinID)
        #expect(model.launchFields.map(\.name) == ["issue", "repo"])
        _ = try window.element(identifier: "launch.field.issue")
        _ = try window.element(identifier: "launch.field.repo")
        #expect((try? window.element(identifier: "launch.repo.resolved")) == nil)
        #expect((try? window.element(identifier: "launch.error")) == nil)
    }

    @Test func launchDisabledUntilRequiredFilled() async throws {
        let (model, _, window) = try await catalogFixture()
        #expect(!model.canLaunch)
        #expect(try !window.element(identifier: "launch.go").isEnabled)
        try await type("   ", into: "launch.field.issue", in: window)
        #expect(!model.canLaunch, "whitespace does not count")
        try await type("42", into: "launch.field.issue", in: window)
        #expect(model.launchForm.values["issue"]?.contains("42") == true)
        #expect(model.canLaunch)
        #expect(try window.element(identifier: "launch.go").isEnabled)
    }

    @Test func launchFormPrefillsRepoDefault() async throws {
        let other = URL(fileURLWithPath: "/other")
        let known = entry("/lib/flows/Known.flow", "Known")
        let unknown = entry("/lib/flows/Unknown.flow", "Unknown")
        let (model, _, window) = try await catalogFixture(repos: [repo, other], extra: [
            (known, repoNodeFlow("Known", mode: .exposed(default: "/other"))),
            (unknown, repoNodeFlow("Unknown", mode: .exposed(default: "/nowhere")))])
        await model.selectFlow(known.id)
        try await window.runUntilIdle()
        #expect(model.launchForm.values["repo"] == "/other")
        try window.click(window.element(identifier: "launch.field.repo"))
        #expect(window.presentedMenu?.items.map(\.title) == ["repo", "other"])
        #expect(window.presentedMenu?.items.first { $0.isOn }?.title == "other")
        try window.dismissMenu()
        await model.selectFlow(unknown.id)
        try await window.runUntilIdle()
        #expect(model.launchForm.values["repo"] == nil, "an unknown default is left to apply at launch")
    }

    @Test func thisRepoFlowShowsResolvedRepo() async throws {
        let inRepo = entry("/repo/.flows/Ship.flow", "Ship")
        let fixed = entry("/lib/flows/Fixed.flow", "Fixed")
        let (model, _, window) = try await catalogFixture(extra: [
            (inRepo, repoNodeFlow("Ship", mode: .thisRepo)),
            (fixed, repoNodeFlow("Fixed", mode: .fixed(path: "/somewhere/proj")))])
        await model.selectFlow(inRepo.id)
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "launch.repo.resolved").value == "repo")
        #expect((try? window.element(identifier: "launch.field.repo")) == nil)
        await model.selectFlow(fixed.id)
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "launch.repo.resolved").value == "proj")
    }

    @Test func launchPassesValuesAndLocation() async throws {
        let (model, client, window) = try await catalogFixture()
        try await type("42", into: "launch.field.issue", in: window)
        try await press("launch.go", in: window)
        let launched = await client.launches
        #expect(launched.count == 1)
        #expect(launched.first?.location == .builtin)
        #expect(launched.first?.values == ["issue": "42", "repo": "/repo"])
        #expect(model.launchForm.values["issue"] == "", "launching clears the typed field")
    }

    @Test func launchSendsAFileFlowsLocation() async throws {
        let inRepo = entry("/repo/.flows/Ship.flow", "Ship")
        let (model, client, window) = try await catalogFixture(extra: [(inRepo, repoNodeFlow("Ship", mode: .thisRepo))])
        await model.selectFlow(inRepo.id)
        try await window.runUntilIdle()
        #expect(model.launchFields.map(\.name) == ["issue"])
        try await type("7", into: "launch.field.issue", in: window)
        try await press("launch.go", in: window)
        let launched = await client.launches
        #expect(launched.first?.location == .of(file: inRepo.file!))
        #expect(launched.first?.values == ["issue": "7"])
    }

    @Test func invalidFlowShowsLaunchError() async throws {
        let bad = entry("/lib/flows/Bad.flow", "Bad")
        let (model, _, window) = try await catalogFixture(extra: [(bad, Flow(name: "Bad", nodes: [], wires: []))])
        await model.selectFlow(bad.id)
        try await window.runUntilIdle()
        #expect(model.launchFields.isEmpty)
        let error = try #require(model.launchError)
        #expect(try window.element(identifier: "launch.error").value == error)
        #expect(!model.canLaunch)
        #expect(try !window.element(identifier: "launch.go").isEnabled)
    }

    @Test func switchingFlowsWhileLoadingAppliesOnlyTheLatest() async throws {
        let a = entry("/lib/flows/A.flow", "A"), b = entry("/lib/flows/B.flow", "B")
        var onlyText = BuiltinFlows.fixGitHubIssue
        onlyText.name = "A"
        let (model, client, _) = try await catalogFixture(extra: [
            (a, onlyText), (b, repoNodeFlow("B", mode: .fixed(path: "/x/proj")))])
        client.files.gate.hold(a.file!)
        let first = Task { await model.selectFlow(a.id) }
        await client.files.gate.waitForEntry()
        #expect(model.isLoadingLaunch)
        #expect(model.launchFields.isEmpty)
        #expect(!model.canLaunch, "nothing launches while the flow is being read")
        await model.selectFlow(b.id)
        #expect(model.launchForm.flow == b.id)
        client.files.gate.release()
        await first.value
        #expect(model.launchForm.flow == b.id)
        #expect(model.launchFields.map(\.name) == ["issue"], "the late result for A is dropped")
        #expect(model.launchResolvedRepo == "proj")
        #expect(!model.isLoadingLaunch)
    }

    @Test func switchingFlowsDropsTheOldFlowsValues() async throws {
        let b = entry("/lib/flows/B.flow", "B")
        let (model, _, window) = try await catalogFixture(extra: [(b, repoNodeFlow("B", mode: .fixed(path: "/x/proj")))])
        try await type("42", into: "launch.field.issue", in: window)
        #expect(model.launchForm.values["issue"]?.contains("42") == true)
        await model.selectFlow(b.id)
        #expect(model.launchForm.values["repo"] == nil)
        #expect(model.launchForm.values == ["issue": ""], "only B's fields, with defaults; nothing typed into A")
    }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mf-add-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func addRepoOpensFolderDialog() async throws {
        let (model, _, window) = try await catalogFixture()
        #expect((try? window.element(identifier: "launch.addrepo")) == nil, "only the repo field's button adds a repo")
        try await press("launch.field.repo.add", in: window)
        let dialog = try #require(window.presentedFileDialog)
        #expect(dialog.canChooseDirectories && !dialog.canChooseFiles)
        #expect(dialog.allowedTypes.map(\.identifier) == ["public.folder"])
        #expect(model.addRepoRequest == .launchField)
        #expect(dialog.prompt == "Add Repository")
        #expect(dialog.message == "Choose a git repository folder")
    }

    @Test func addRepoAddsChosenFolder() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.standardizedFileURL.path
        let (model, client, window) = try await catalogFixture(gitRepos: [path])
        try await press("launch.field.repo.add", in: window)
        try window.respondToFileDialog(choosing: [dir.path])
        try await window.runUntil { model.repos.map(\.path).contains(path) }
        #expect(client.knownRepos().map(\.path).contains(path), "persisted through the client")
        let fresh = AppModel(client: client, notifier: NoopNotifier())
        await fresh.refreshRepos()
        #expect(fresh.repos.map(\.path).contains(path))
        #expect(model.addRepoRequest == nil)
        #expect(model.notice == nil)
        #expect(window.presentedFileDialog == nil)
    }

    @Test func addRepoRejectsNonRepoFolder() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (model, _, window) = try await catalogFixture()
        try await press("launch.field.repo.add", in: window)
        try window.respondToFileDialog(choosing: [dir.path])
        try await window.runUntil { model.notice != nil }
        #expect(model.repos.map(\.path) == ["/repo"])
    }

    @Test func addRepoCancelAddsNothing() async throws {
        let (model, _, window) = try await catalogFixture()
        try await press("launch.field.repo.add", in: window)
        try window.cancelFileDialog()
        try await window.runUntilIdle()
        #expect(model.addRepoRequest == nil)
        #expect(model.repos.map(\.path) == ["/repo"])
        #expect(model.notice == nil)
    }

    @Test func launchFieldAddSelectsNewRepo() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.standardizedFileURL.path
        let (model, _, window) = try await catalogFixture(gitRepos: [path])
        try await press("launch.field.repo.add", in: window)
        #expect(model.addRepoRequest == .launchField)
        try window.respondToFileDialog(choosing: [dir.path])
        try await window.runUntil { model.launchForm.values["repo"] == path }
        #expect(model.repos.map(\.path).contains(path))
    }

    @Test func addRepoKeepsTheRepoForTheSessionWhenSavingFails() async throws {
        let (model, client, _) = try await fixture(gitRepos: ["/other"])
        await client.setFailure(FakeFailure())
        #expect(await model.addRepo(path: "/other"))
        #expect(model.notice != nil)
        #expect(model.repos.map(\.path).contains("/other"))
    }

    @Test func addRepoValidatesThePath() async throws {
        let (model, _, _) = try await fixture(gitRepos: ["/other"])
        #expect(await model.addRepo(path: "/nope") == false)
        #expect(model.notice != nil)
        #expect(await model.addRepo(path: "/other"))
        #expect(model.repos.map(\.path) == ["/repo", "/other"])
        #expect(model.selectedRepo?.path == "/other")
    }

    @Test func needsYouCardsAppearPerKind() async throws {
        let pick = makeRun("pick", status: .needsYou, nodes: [
            NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))])
        let ask = makeRun("ask", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.question("Which file?")))])
        let cut = makeRun("cut", status: .needsYou, nodes: [NodeKey(node: "plan"): NodeRun(state: .interrupted)])
        let bad = makeRun("bad", status: .needsYou, nodes: [NodeKey(node: "gate", lane: "a"): NodeRun(state: .failed("nope"))])
        let (_, _, window) = try await fixture([pick, ask, cut, bad])

        _ = try window.element(identifier: "needs.\(pick.id.rawValue).pick")
        _ = try window.element(identifier: "needs.\(pick.id.rawValue).pick.primary")
        #expect(try window.element(identifier: "needs.\(pick.id.rawValue).pick.primary").label == "Compare & pick")
        _ = try window.element(identifier: "needs.\(ask.id.rawValue).plan")
        _ = try window.element(identifier: "answer.\(ask.id.rawValue).plan.field")
        #expect(try window.element(identifier: "needs.\(cut.id.rawValue).plan.primary").label == "Resume")
        #expect(try window.element(identifier: "needs.\(bad.id.rawValue).gate@a.primary").label == "Retry")
        for run in [pick, ask, cut, bad] {
            let key = run.nodes.keys.first!
            _ = try window.element(identifier: "needs.\(run.id.rawValue).\(key).open")
        }
    }

    @Test func compareAndPickAndOpenRunSelectTheRun() async throws {
        let pick = makeRun("pick", status: .needsYou, nodes: [
            NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))])
        let ask = makeRun("ask", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.question("Which file?")))])
        let (model, _, window) = try await fixture([pick, ask])
        try await press("needs.\(pick.id.rawValue).pick.primary", in: window)
        #expect(model.selectedRun == pick.id)
        model.selectedRun = nil
        try await window.runUntilIdle()
        try await press("needs.\(ask.id.rawValue).plan.open", in: window)
        #expect(model.selectedRun == ask.id)
    }

    @Test func aFailedRunWithAFailedNodeShowsARetryCard() async throws {
        let failed = makeRun("failed", status: .failed("boom"), nodes: [
            NodeKey(node: "plan"): NodeRun(state: .failed("boom"))])
        let (model, client, window) = try await fixture([failed])
        #expect(model.finished.isEmpty)
        #expect(model.needsYou.map(\.id) == [failed.id])
        #expect(try window.element(identifier: "needs.\(failed.id.rawValue).plan.primary").label == "Retry")
        try await press("needs.\(failed.id.rawValue).plan.primary", in: window)
        #expect(await client.calls.contains("retry(plan)"))
    }

    @Test func doubleSubmitLaunchesOnce() async throws {
        let (model, client, _) = try await fixture()
        model.launchForm.values["issue"] = "42"
        async let a = model.launchFromForm()
        async let b = model.launchFromForm()
        _ = await (a, b)
        let launches = await client.calls.filter { $0.hasPrefix("launch(") }
        #expect(launches.count == 1)
    }

    @Test func textTypedDuringALaunchSurvives() async throws {
        let (model, client, window) = try await fixture()
        await client.holdLaunches()
        model.launchForm.values["issue"] = "42"
        let task = Task { await model.launchFromForm() }
        try await window.runUntil { model.isLaunching }
        #expect(model.isLaunching)
        #expect(!model.canLaunch)
        model.launchForm.values["issue"] = "43"
        await client.releaseLaunches()
        _ = await task.value
        #expect(model.launchForm.values["issue"] == "43")
        #expect(!model.isLaunching)

        model.launchForm.values["issue"] = "44"
        _ = await model.launchFromForm()
        #expect(model.launchForm.values["issue"] == "", "an unchanged field is cleared")
    }

    @Test func retryAndResumeCallTheClient() async throws {
        let cut = makeRun("cut", status: .needsYou, nodes: [NodeKey(node: "plan"): NodeRun(state: .interrupted)])
        let bad = makeRun("bad", status: .needsYou, nodes: [NodeKey(node: "gate", lane: "a"): NodeRun(state: .failed("nope"))])
        let (_, client, window) = try await fixture([cut, bad])
        try await press("needs.\(cut.id.rawValue).plan.primary", in: window)
        try await press("needs.\(bad.id.rawValue).gate@a.primary", in: window)
        let calls = await client.calls
        #expect(calls.contains("resume"))
        #expect(calls.contains("retry(gate@a)"))
    }

    @Test func answerFromDashboardCallsClient() async throws {
        let ask = makeRun("ask", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.question("Which file?")))])
        let (_, client, window) = try await fixture([ask])
        try window.click(window.element(identifier: "answer.\(ask.id.rawValue).plan.field"))
        window.typeText("Use A.swift")
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "answer.\(ask.id.rawValue).plan.field").value == "Use A.swift")
        try await press("answer.\(ask.id.rawValue).plan.send", in: window)
        #expect(await client.calls.contains("answer(plan, Use A.swift, [])"))
    }

    @Test func runLockedByAnotherProcessIsLabelledAndHasNoCancel() async throws {
        let mine = makeRun("mine", status: .running), theirs = makeRun("theirs", status: .running)
        let client = FakeEngineClient(restored: [mine, theirs], repos: [repo], flowFiles: [flowFile])
        await client.setElsewhere([theirs.id])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        try await window.runUntilIdle()
        #expect(model.runningElsewhere == [theirs.id])
        #expect(model.drivenRunning.map(\.id) == [mine.id])
        _ = try window.element(identifier: "run.\(mine.id.rawValue).cancel")
        #expect((try? window.element(identifier: "run.\(theirs.id.rawValue).cancel")) == nil)
        #expect(try window.element(identifier: "run.\(theirs.id.rawValue).elsewhere").value == "Running in another mflow")
        // Only the run this app drives is stopped by quitting.
        #expect(model.requestTerminate() == .later)
        #expect(model.quitMessage == "1 run is still running. Quitting stops it — you can resume later.")
        // An update from this app's own engine means it drives the run now.
        var taken = theirs
        taken.revision = 1
        model.apply(taken)
        #expect(model.runningElsewhere.isEmpty)
    }

    func elsewhereFixture(_ theirs: Run) async throws -> (AppModel, FakeEngineClient, RecordingNotifier) {
        let client = FakeEngineClient(restored: [theirs], repos: [repo], flowFiles: [flowFile])
        await client.setElsewhere([theirs.id])
        let notifier = RecordingNotifier()
        let model = AppModel(client: client, notifier: notifier)
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        await model.flushNotifications()
        #expect(model.runningElsewhere == [theirs.id])
        return (model, client, notifier)
    }

    @Test func elsewhereClearsWhenLockReleased() async throws {
        let theirs = makeRun("theirs", status: .running)
        let (model, client, _) = try await elsewhereFixture(theirs)
        var done = theirs
        done.revision = 3
        done.status = .completed
        await client.setReload(done)
        await client.setElsewhere([])
        await model.refreshElsewhere()
        #expect(model.runningElsewhere.isEmpty)
        #expect(model.runs[theirs.id]?.status == .completed)
        #expect(model.statusText(done) != "Running in another mflow")
    }

    @Test func elsewhereShowsOtherProcessProgress() async throws {
        let theirs = makeRun("theirs", status: .running)
        let (model, client, _) = try await elsewhereFixture(theirs)
        var moved = theirs
        moved.revision = 2
        moved.nodes[NodeKey(node: "plan")] = NodeRun(state: .succeeded, output: "planned")
        await client.setReload(moved)
        await model.refreshElsewhere()
        #expect(model.runs[theirs.id]?.nodes[NodeKey(node: "plan")]?.state == .succeeded)
        #expect(model.running.first?.revision == 2)
        #expect(model.runningElsewhere == [theirs.id], "still locked, so still theirs")
    }

    @Test func elsewhereStaysWhileLocked() async throws {
        let theirs = makeRun("theirs", status: .running)
        let (model, client, _) = try await elsewhereFixture(theirs)
        await model.refreshElsewhere()
        await model.refreshElsewhere()
        #expect(model.runningElsewhere == [theirs.id])
        #expect(model.statusText(theirs) == "Running in another mflow")
        #expect(await client.calls.filter { $0 == "reload" }.count == 2)
    }

    @Test func elsewhereDoesNotNotifyTwice() async throws {
        let theirs = makeRun("theirs", status: .running)
        let (model, client, notifier) = try await elsewhereFixture(theirs)
        var asks = theirs
        asks.revision = 1
        asks.status = .needsYou
        asks.nodes[NodeKey(node: "pick")] = NodeRun(state: .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))
        await client.setReload(asks)
        await model.refreshElsewhere()
        await model.refreshElsewhere()
        await model.flushNotifications()
        #expect(notifier.posts.count == 1)
    }

    @Test func startPollsElsewhereUntilItEnds() async throws {
        let theirs = makeRun("theirs", status: .running)
        let client = FakeEngineClient(restored: [theirs], repos: [repo], flowFiles: [flowFile])
        await client.setElsewhere([theirs.id])
        let (ticks, tick) = AsyncStream.makeStream(of: Void.self)
        let model = AppModel(client: client, notifier: NoopNotifier(), pause: { for await _ in ticks { return } })
        let start = Task { await model.start() }
        await model.waitUntilReady()
        #expect(model.runningElsewhere == [theirs.id])
        await client.setElsewhere([])
        tick.yield()
        await waitUntil("the poll to clear the run") { model.runningElsewhere.isEmpty }
        await client.finish()
        await start.value
        tick.finish()
    }

    @Test func discoveredRunAppearsOnDashboard() async throws {
        let (model, client, _) = try await elsewhereFixture(makeRun("theirs", status: .running))
        let fresh = makeRun("fresh", status: .completed, createdAt: Date(timeIntervalSince1970: 2_000))
        await client.setDiscoverable([fresh])
        await model.discoverRuns()
        #expect(model.runs[fresh.id] != nil)
        #expect(model.finished.map(\.id) == [fresh.id])
        #expect(!model.runningElsewhere.contains(fresh.id))
    }

    @Test func discoveredRunningRunIsMarkedElsewhere() async throws {
        let (model, client, _) = try await elsewhereFixture(makeRun("theirs", status: .running))
        let fresh = makeRun("fresh", status: .running)
        await client.setDiscoverable([fresh])
        await client.setElsewhere([fresh.id])
        await model.discoverRuns()
        #expect(model.runningElsewhere.contains(fresh.id))
        #expect(model.statusText(fresh) == "Running in another mflow")
        #expect(model.running.contains { $0.id == fresh.id })
    }

    @Test func discoveredNeedsYouRunNotifiesOnce() async throws {
        let (model, client, notifier) = try await elsewhereFixture(makeRun("theirs", status: .running))
        let fresh = makeRun("asks", status: .needsYou, nodes: [
            NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))])
        await client.setDiscoverable([fresh])
        await model.discoverRuns()
        await model.discoverRuns()
        await model.flushNotifications()
        #expect(notifier.posts.count == 1)
        #expect(model.needsYou.map(\.id) == [fresh.id])
    }

    @Test func knownRunNotRediscovered() async throws {
        let theirs = makeRun("theirs", status: .running)
        let (model, client, _) = try await elsewhereFixture(theirs)
        var stale = theirs
        stale.title = "stale copy"
        await client.setDiscoverable([stale])
        await model.discoverRuns()
        #expect(model.runs[theirs.id]?.title == "theirs")
        #expect(model.running.count == 1)
    }

    @Test func vanishedRunLeavesDashboard() async throws {
        let theirs = makeRun("theirs", status: .running)
        let keep = makeRun("keep", status: .completed, createdAt: Date(timeIntervalSince1970: 2_000))
        let (model, client, _) = try await elsewhereFixture(theirs)
        await client.setDiscoverable([keep])
        await model.discoverRuns()
        model.open(run: theirs.id)
        await client.setVanished([theirs.id])
        await model.discoverRuns()
        #expect(model.runs[theirs.id] == nil)
        #expect(!model.order.contains(theirs.id))
        #expect(model.finished.map(\.id) == [keep.id])
        #expect(model.running.isEmpty)
        #expect(model.runningElsewhere.isEmpty)
        #expect(!model.workingOn.contains(.run(theirs.id)))
    }

    @Test func vanishedRunClosesItsDetail() async throws {
        let theirs = makeRun("theirs", status: .running)
        let (model, client, _) = try await elsewhereFixture(theirs)
        model.open(run: theirs.id)
        #expect(model.selectedRun == theirs.id)
        await client.setVanished([theirs.id])
        await model.discoverRuns()
        #expect(model.selectedRun == nil)
        #expect(model.screen == .dashboard)
        #expect(model.notice == Notice("This run was discarded elsewhere."))
    }

    @Test func vanishedNeedsYouRunClearsNotificationAndBadge() async throws {
        let ask = makeRun("asks", status: .needsYou, nodes: [
            NodeKey(node: "pick"): NodeRun(state: .needsYou(.pickWinner(recommended: "b", allGatesFailed: false)))])
        let (model, client, notifier) = try await elsewhereFixture(makeRun("theirs", status: .running))
        await client.setDiscoverable([ask])
        await model.discoverRuns()
        await model.flushNotifications()
        #expect(notifier.badges.last == 1)
        await client.setVanished([ask.id])
        await model.discoverRuns()
        await model.flushNotifications()
        #expect(model.needsYou.isEmpty)
        #expect(notifier.events.contains(.remove(id: ask.id.rawValue)))
        #expect(notifier.badges.last == 0)
    }

    @Test func quitWithOnlyOtherProcessRunsQuitsNow() async throws {
        let theirs = makeRun("theirs", status: .running)
        let client = FakeEngineClient(restored: [theirs], repos: [repo])
        await client.setElsewhere([theirs.id])
        let model = AppModel(client: client, notifier: NoopNotifier())
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        await model.waitUntilReady()
        #expect(model.requestTerminate() == .now)
    }

    @Test func failedAnswerKeepsTheReply() async throws {
        let ask = makeRun("ask", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.question("Which file?")))])
        let (model, client, window) = try await fixture([ask])
        await client.setFailure(FakeFailure())
        try window.click(window.element(identifier: "answer.\(ask.id.rawValue).plan.field"))
        window.typeText("Use A.swift")
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "answer.\(ask.id.rawValue).plan.field").value == "Use A.swift")
        try await press("answer.\(ask.id.rawValue).plan.send", in: window)
        #expect(await client.calls.contains("answer(plan, Use A.swift, [])"))
        #expect(model.answerDrafts[AppModel.draftKey(ask.id, NodeKey(node: "plan"))] == "Use A.swift", "kept for another try")
        #expect(model.notice?.text == "engine said no")
        // A successful answer clears it.
        await client.setFailure(nil)
        try await press("answer.\(ask.id.rawValue).plan.send", in: window)
        #expect(model.answerDrafts[AppModel.draftKey(ask.id, NodeKey(node: "plan"))] == nil)
    }

    @Test func newlineOnlyReplyCannotBeSent() async throws {
        let ask = makeRun("ask", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.question("Which file?")))])
        let (model, _, window) = try await fixture([ask])
        model.answerDrafts[AppModel.draftKey(ask.id, NodeKey(node: "plan"))] = " \n "
        try await window.runUntilIdle()
        #expect(try !window.element(identifier: "answer.\(ask.id.rawValue).plan.send").isEnabled)
    }

    @Test func allowOnTheDashboardSendsTheSameReplyAsTheDetail() async throws {
        let run = makeRun("denied", status: .needsYou, nodes: [
            NodeKey(node: "plan"): NodeRun(state: .needsYou(.deniedTools(["Edit"])))])
        let (_, client, window) = try await fixture([run])
        try await press("needs.\(run.id.rawValue).plan.primary", in: window)
        #expect(await client.calls.contains("answer(plan, Continue., [\"Edit\"])"))
    }

    @Test func runningCardShowsStepPillsAndLastLog() async throws {
        let started = Date().addingTimeInterval(-150)
        let run = makeRun("#63 Word diff", status: .running, createdAt: started, nodes: [
            NodeKey(node: "issue"): NodeRun(state: .succeeded),
            NodeKey(node: "repo"): NodeRun(state: .succeeded),
            NodeKey(node: "plan"): NodeRun(state: .succeeded),
            NodeKey(node: "implement", lane: "a"): NodeRun(state: .succeeded),
            NodeKey(node: "implement", lane: "b"): NodeRun(state: .running, log: ["▸ Edit DiffView.swift"], startedAt: started),
        ])
        let (_, _, window) = try await fixture([run])
        let id = run.id.rawValue
        #expect(try window.element(identifier: "run.\(id).title").value == "#63 Word diff")
        #expect(try window.element(identifier: "run.\(id).log").value == "▸ Edit DiffView.swift")
        let pillIDs = try window.elements { ($0.identifier ?? "").hasPrefix("pill.") }
            .sorted { $0.frame.origin.x < $1.frame.origin.x }.compactMap(\.identifier)
        let names = pillIDs.map { String($0.split(separator: ".")[1]) }
        #expect(names == (try run.flow.validate().order.map(\.rawValue)))
        #expect(names.firstIndex(of: "plan")! < names.firstIndex(of: "implement")!)
        #expect(names.firstIndex(of: "implement")! < names.firstIndex(of: "gate")!)
        _ = try window.element(identifier: "pill.plan.done")
        _ = try window.element(identifier: "pill.implement.run")
        _ = try window.element(identifier: "pill.gate.wait")
        _ = try window.element(identifier: "pill.pick.wait")

        #expect(try window.element(identifier: "run.\(id).elapsed").value == "2m")
        window.advance(by: 60)
        #expect(try window.element(identifier: "run.\(id).elapsed").value == "3m")
    }

    @Test func cancelFromRunCard() async throws {
        let run = makeRun("go", status: .running)
        let (_, client, window) = try await fixture([run])
        try await press("run.\(run.id.rawValue).cancel", in: window)
        #expect(await client.calls.contains("cancel"))
    }

    @Test func finishedListsMergedRuns() async throws {
        let old = makeRun("#39 old", status: .merged("a"), createdAt: Date(timeIntervalSince1970: 1_000))
        let new = makeRun("#40 new", status: .discarded, createdAt: Date(timeIntervalSince1970: 2_000))
        let (model, _, window) = try await fixture([old, new])
        #expect(model.finished.map(\.title) == ["#40 new", "#39 old"])
        let rows = try window.elements { ($0.identifier ?? "").hasPrefix("finished.") && ($0.identifier ?? "").hasSuffix(".title") }
            .sorted { $0.frame.origin.y < $1.frame.origin.y }.compactMap(\.value)
        #expect(rows == ["#40 new", "#39 old"], "rendered newest first")
        #expect(try window.element(identifier: "finished.\(old.id.rawValue).result").value == "Merged A")
        #expect(try window.element(identifier: "finished.\(new.id.rawValue).result").value == "Discarded")
    }

    @Test func finishedListCapsAtTwenty() async throws {
        let runs = (0..<25).map { makeRun("r\($0)", status: .completed, createdAt: Date(timeIntervalSince1970: Double(1_000 + $0))) }
        let (_, _, window) = try await fixture(runs)
        let rows = try window.elements { ($0.identifier ?? "").hasPrefix("finished.") && ($0.identifier ?? "").hasSuffix(".title") }
            .sorted { $0.frame.origin.y < $1.frame.origin.y }.compactMap(\.value)
        #expect(rows == (5..<25).reversed().map { "r\($0)" }, "the 20 newest, newest first")
    }

    @Test func workingChipOpensAndDismisses() async throws {
        let run = makeRun("#7 x", status: .running)
        let (model, _, window) = try await fixture([run])
        model.open(run: run.id)
        try await window.runUntilIdle()
        model.selectedRun = nil
        try await window.runUntilIdle()
        try await press("working.run.\(run.id.rawValue).open", in: window)
        #expect(model.selectedRun == run.id)
        model.selectedRun = nil
        try await window.runUntilIdle()
        try await press("working.run.\(run.id.rawValue).dismiss", in: window)
        #expect(model.workingOn.isEmpty)
    }

    @Test func activityFeedShowsItems() async throws {
        let run = makeRun("#9 feed", status: .running)
        let (model, _, window) = try await fixture()
        model.apply(run)
        try await window.runUntilIdle()
        #expect(try window.elements { $0.identifier == "activity.item" }.count == 1)
    }

    @Test func idsSitOnTheRealContainers() async throws {
        let run = makeRun("#1 card", status: .running)
        let (_, _, window) = try await fixture([run])
        let screen = try window.element(identifier: "dashboard").frame
        #expect(screen.size.width > 1000 && screen.size.height > 500, "the screen, not a zero-size marker")
        let card = try window.element(identifier: "run.\(run.id.rawValue)").frame
        let cancel = try window.element(identifier: "run.\(run.id.rawValue).cancel").frame
        #expect(card.size.width > 200 && card.size.height > 80)
        #expect(cancel.origin.x >= card.origin.x && cancel.origin.y >= card.origin.y)
        #expect(cancel.origin.x + cancel.size.width <= card.origin.x + card.size.width)
        #expect(cancel.origin.y + cancel.size.height <= card.origin.y + card.size.height, "the card's frame holds its buttons")
    }

    @Test func activityFeedBuildsOnlyTheVisibleRows() async throws {
        let (model, _, window) = try await fixture()
        for i in 0..<150 { model.apply(makeRun("run \(i)", status: .running, createdAt: Date(timeIntervalSince1970: Double(i)))) }
        try await window.runUntilIdle()
        #expect(model.activity.count == 150)
        let rows = try window.elements { $0.identifier == "activity.item" }.count
        #expect(rows > 0 && rows < 60, "\(rows) rows built for 150 items")
    }

    @Test func workingChipIDsAreUniqueAcrossRepos() async throws {
        let (model, _, window) = try await fixture()
        model.open(flow: URL(fileURLWithPath: "/a/x.flow"))
        model.open(flow: URL(fileURLWithPath: "/b/x.flow"))
        model.screen = .dashboard
        try await window.runUntilIdle()
        let chips = try window.elements { ($0.identifier ?? "").hasPrefix("working.flow.") && !($0.identifier ?? "").hasSuffix("title") && !($0.identifier ?? "").hasSuffix("open") && !($0.identifier ?? "").hasSuffix("dismiss") }
        #expect(Set(chips.compactMap(\.identifier)).count == 2)
        let titles = try window.elements { ($0.identifier ?? "").hasPrefix("working.flow.") && ($0.identifier ?? "").hasSuffix(".title") }
        #expect(Set(titles.compactMap(\.identifier)).count == 2)
    }

    @Test func agesFollowTheModelClock() async throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let run = makeRun("old", status: .completed, createdAt: now.addingTimeInterval(-7_200))
        let client = FakeEngineClient(restored: [run], repos: [repo], flowFiles: [flowFile])
        let model = AppModel(client: client, notifier: NoopNotifier(), clock: { now })
        let window = try appWindow(model: model)
        try await window.runUntilIdle()
        #expect(try window.element(identifier: "finished.\(run.id.rawValue).age").value == "2h")
    }

    @Test func isLaunchingResetsAfterALaunchThrows() async throws {
        let (model, client, _) = try await fixture()
        await client.setFailure(FakeFailure())
        model.launchForm.values["issue"] = "42"
        #expect(await model.launchFromForm() == nil)
        #expect(!model.isLaunching)
        #expect(model.launchForm.values["issue"] == "42", "a failed launch keeps the text")
        #expect(model.notice != nil)
    }
}

