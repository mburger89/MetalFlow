import Foundation
import Testing
@testable import MetalFlowCore

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("catalog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ name: String, to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FlowFile.save(Flow(name: name, nodes: [], wires: []), to: file)
}

private func flow(_ mode: RepoMode) -> Flow {
    Flow(name: "f", nodes: [Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: mode)), position: Point(x: 0, y: 0))], wires: [])
}

private func mode(_ flow: Flow) -> RepoMode? {
    for n in flow.nodes { if case .repo(let c) = n.kind { return c.mode } }
    return nil
}

@Suite struct FlowCatalogTests {
    @Test func catalogOrdersBuiltinsLibraryRepos() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = dir.appendingPathComponent("lib")
        try write("B", to: library.appendingPathComponent("b.flow"))
        try write("A", to: library.appendingPathComponent("a.flow"))
        let r1 = dir.appendingPathComponent("r1"), r2 = dir.appendingPathComponent("r2")
        try write("R2", to: r2.appendingPathComponent(".flows/x.flow"))
        try write("R1", to: r1.appendingPathComponent(".flows/y.flow"))

        let entries = FlowCatalog.entries(library: library, repos: [r2, r1])
        #expect(entries.map(\.name) == ["Fix GitHub issue", "A", "B", "R2", "R1"])
        #expect(entries[0].location == .builtin)
        #expect(entries[0].file == nil)
        #expect(entries[0].id == "builtin:Fix GitHub issue")
        // Directory listings come back with /private resolved; compare resolved paths.
        func resolved(_ u: URL?) -> String? { u?.resolvingSymlinksInPath().path }
        let a = library.appendingPathComponent("a.flow")
        #expect(resolved(entries[1].file) == resolved(a))
        #expect(entries[1].id == entries[1].file?.path)
        if case .library(let f) = entries[1].location { #expect(resolved(f) == resolved(a)) } else { Issue.record("not library") }
        if case .repo(let root, let f) = entries[3].location {
            #expect(resolved(root) == resolved(r2))
            #expect(resolved(f) == resolved(r2.appendingPathComponent(".flows/x.flow")))
        } else { Issue.record("not repo") }
    }

    @Test func catalogReadsFlowNames() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("Pretty Name", to: dir.appendingPathComponent("file-stem.flow"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("broken.flow"))
        let entries = FlowCatalog.entries(library: dir, repos: [])
        #expect(entries.map(\.name) == ["Fix GitHub issue", "broken", "Pretty Name"])
    }

    @Test func catalogSkipsMissingRepoFolder() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let entries = FlowCatalog.entries(library: dir.appendingPathComponent("nope"), repos: [dir.appendingPathComponent("gone")])
        #expect(entries.map(\.name) == ["Fix GitHub issue"])
    }

    @Test func thisRepoSavedToLibraryBecomesExposedWithDefault() {
        let origin = URL(fileURLWithPath: "/work/myrepo")
        let dest = FlowLocation.library(file: URL(fileURLWithPath: "/lib/a.flow"))
        let (out, notice) = FlowCatalog.prepareForSave(flow(.thisRepo), destination: dest, origin: origin)
        #expect(mode(out) == .exposed(default: "/work/myrepo"))
        #expect(notice == "Saved to the library: the repo is now asked at launch (defaults to myrepo).")

        let (out2, notice2) = FlowCatalog.prepareForSave(flow(.thisRepo), destination: dest, origin: nil)
        #expect(mode(out2) == .exposed(default: nil))
        #expect(notice2 == "Saved to the library: the repo is now asked at launch (no default).")
    }

    @Test func exposedSavedToRepoBecomesThisRepo() {
        let root = URL(fileURLWithPath: "/work/r")
        let dest = FlowLocation.repo(root: root, file: root.appendingPathComponent(".flows/a.flow"))
        let (out, notice) = FlowCatalog.prepareForSave(flow(.exposed(default: nil)), destination: dest, origin: nil)
        #expect(mode(out) == .thisRepo)
        #expect(notice == nil)
        let (kept, _) = FlowCatalog.prepareForSave(flow(.exposed(default: "/x")), destination: dest, origin: nil)
        #expect(mode(kept) == .exposed(default: "/x"))
    }

    @Test func orphanBindingsDroppedOnSave() {
        var f = flow(.thisRepo)
        f.nodes.append(Node(id: "a", title: "A", kind: .prompt(PromptConfig(model: "sonnet", prompt: "{x}", candidates: [], allowedTools: [], maxTurns: nil)),
                            position: Point(x: 0, y: 0), inputs: ["x": .fixed("v"), "gone": .exposed(default: nil)]))
        let root = URL(fileURLWithPath: "/work/r")
        let dest = FlowLocation.repo(root: root, file: root.appendingPathComponent(".flows/a.flow"))
        let (out, _) = FlowCatalog.prepareForSave(f, destination: dest, origin: nil)
        #expect(out.node("a")?.inputs == ["x": .fixed("v")])
    }

    @Test func fixedUnchangedOnSave() {
        let root = URL(fileURLWithPath: "/work/r")
        let dests: [FlowLocation] = [.library(file: URL(fileURLWithPath: "/lib/a.flow")), .repo(root: root, file: root.appendingPathComponent(".flows/a.flow"))]
        for d in dests {
            let (out, notice) = FlowCatalog.prepareForSave(flow(.fixed(path: "/p")), destination: d, origin: root)
            #expect(mode(out) == .fixed(path: "/p"))
            #expect(notice == nil)
        }
    }

    @Test func copyToRepoMakesEveryRepoModeThisRepo() {
        let root = URL(fileURLWithPath: "/work/r")
        let dest = FlowLocation.repo(root: root, file: root.appendingPathComponent(".flows/a.flow"))
        for m: RepoMode in [.fixed(path: "/p"), .exposed(default: "x"), .exposed(default: nil), .thisRepo] {
            let (out, _) = FlowCatalog.prepareForCopy(flow(m), destination: dest, origin: nil)
            #expect(mode(out) == .thisRepo)
        }
    }

    @Test func copyToLibraryExposesThisRepoWithOriginDefault() {
        let origin = URL(fileURLWithPath: "/work/myrepo")
        let dest = FlowLocation.library(file: URL(fileURLWithPath: "/lib/a.flow"))
        let (out, notice) = FlowCatalog.prepareForCopy(flow(.thisRepo), destination: dest, origin: origin)
        #expect(mode(out) == .exposed(default: "/work/myrepo"))
        #expect(notice == "Saved to the library: the repo is now asked at launch (defaults to myrepo).")
        let (fixed, fixedNotice) = FlowCatalog.prepareForCopy(flow(.fixed(path: "/p")), destination: dest, origin: origin)
        #expect(mode(fixed) == .fixed(path: "/p") && fixedNotice == nil)
    }

    @Test func copyDropsOrphanBindings() {
        var f = flow(.thisRepo)
        f.nodes.append(Node(id: "a", title: "A", kind: .prompt(PromptConfig(model: "sonnet", prompt: "{x}", candidates: [], allowedTools: [], maxTurns: nil)),
                            position: Point(x: 0, y: 0), inputs: ["x": .fixed("v"), "gone": .exposed(default: nil)]))
        let root = URL(fileURLWithPath: "/work/r")
        for d in [FlowLocation.library(file: URL(fileURLWithPath: "/lib/a.flow")), .repo(root: root, file: root.appendingPathComponent(".flows/a.flow"))] {
            #expect(FlowCatalog.prepareForCopy(f, destination: d, origin: root).0.node("a")?.inputs == ["x": .fixed("v")])
        }
    }

    @Test func newFileURLNeverOverwrites() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FlowCatalog.newFileURL(name: "My Flow!", in: dir)
        #expect(first.lastPathComponent == "my-flow.flow")
        try Data().write(to: first)
        let second = FlowCatalog.newFileURL(name: "My Flow!", in: dir)
        #expect(second.lastPathComponent == "my-flow-2.flow")
        try Data().write(to: second)
        #expect(FlowCatalog.newFileURL(name: "My Flow!", in: dir).lastPathComponent == "my-flow-3.flow")
    }

    @Test func storeFlowsDirectory() {
        let store = RunStore(root: URL(fileURLWithPath: "/r"))
        #expect(store.flowsDirectory.path == "/r/flows")
    }

    private func entry(_ name: String, _ path: String?) -> FlowEntry {
        let file = path.map { URL(fileURLWithPath: $0) }
        return FlowEntry(id: path ?? "builtin:\(name)", name: name, location: file.map { .library(file: $0) } ?? .builtin, file: file)
    }

    @Test func resolveMatchesFileStem() throws {
        let entries = [entry("Fix GitHub issue", nil), entry("Fix an issue", "/repo/.flows/fix-issue.flow")]
        #expect(try FlowCatalog.resolve(flowArgument: "fix-issue", entries: entries).id == "/repo/.flows/fix-issue.flow")
        #expect(try FlowCatalog.resolve(flowArgument: "Fix-Issue", entries: entries).id == "/repo/.flows/fix-issue.flow")
    }

    @Test func resolveNameAndStemOfSameEntryIsOneMatch() throws {
        let entries = [entry("deploy", "/lib/deploy.flow")]
        #expect(try FlowCatalog.resolve(flowArgument: "deploy", entries: entries).id == "/lib/deploy.flow")
    }

    @Test func resolveStemAmbiguousAcrossLocations() {
        let entries = [entry("A", "/lib/fix-issue.flow"), entry("B", "/repo/.flows/fix-issue.flow")]
        #expect(throws: LaunchArgumentError.ambiguousFlow("fix-issue", ["/lib/fix-issue.flow", "/repo/.flows/fix-issue.flow"])) {
            _ = try FlowCatalog.resolve(flowArgument: "fix-issue", entries: entries)
        }
    }

    @Test func resolveNameMatchedByOneAndStemByAnotherIsAmbiguous() {
        let entries = [entry("deploy", "/lib/a.flow"), entry("Other", "/lib/deploy.flow")]
        #expect(throws: LaunchArgumentError.self) { _ = try FlowCatalog.resolve(flowArgument: "deploy", entries: entries) }
    }
}
