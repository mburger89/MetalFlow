import Foundation
import Testing
@testable import MetalFlowCore

@Suite struct FlowNoteTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("f.flow")
    }

    private let notes = [
        FlowNote(id: "note1", text: "Remember", origin: Point(x: 10, y: 20), width: 200, height: 120, surrounds: false),
        FlowNote(id: "note2", text: "Plan", origin: Point(x: -5, y: 0), width: 300, height: 180, surrounds: true),
    ]

    @Test func flowWithoutNotesKeyDecodes() throws {
        let json = #"{"name":"x","wires":[],"nodes":[{"id":"repo","title":"Repo","kind":{"repo":{}},"position":{"x":5,"y":6}}]}"#
        let flow = try JSONDecoder().decode(Flow.self, from: Data(json.utf8))
        #expect(flow.notes.isEmpty)
        #expect(flow.nodes.count == 1)
    }

    @Test func flowWithoutNotesEncodesNoNotesKey() throws {
        let data = try JSONEncoder().encode(BuiltinFlows.fixGitHubIssue)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["notes"] == nil)
        #expect(Set(object.keys) == ["name", "nodes", "wires"])
        var withNote = BuiltinFlows.fixGitHubIssue
        withNote.notes = notes
        let object2 = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(withNote)) as? [String: Any])
        #expect((object2["notes"] as? [Any])?.count == 2)
    }

    @Test func notesRoundTripThroughFlowFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var flow = BuiltinFlows.fixGitHubIssue
        flow.notes = notes
        try FlowFile.save(flow, to: url)
        let loaded = try FlowFile.load(from: url)
        #expect(loaded.notes == notes)
        #expect(loaded == flow)
        #expect(flow.droppingOrphanBindings().notes == notes)
    }

    @Test func preparingForSaveOrCopyKeepsNotes() {
        var flow = BuiltinFlows.fixGitHubIssue
        flow.notes = notes
        let library = FlowLocation.library(file: URL(fileURLWithPath: "/lib/x.flow"))
        let repo = FlowLocation.repo(root: URL(fileURLWithPath: "/r"), file: URL(fileURLWithPath: "/r/.flows/x.flow"))
        #expect(FlowCatalog.prepareForSave(flow, destination: library, origin: nil).0.notes == notes)
        #expect(FlowCatalog.prepareForSave(flow, destination: repo, origin: nil).0.notes == notes)
        #expect(FlowCatalog.prepareForCopy(flow, destination: repo, origin: nil).0.notes == notes)
    }

    @Test func aNoteLessFlowSavesWithoutANotesKey() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FlowFile.save(BuiltinFlows.fixGitHubIssue, to: url)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("notes"))
    }

    @Test func runRecordWithNotesRoundTrips() throws {
        var flow = BuiltinFlows.fixGitHubIssue
        flow.notes = notes
        let run = Run(flow: flow, title: "t", repo: URL(fileURLWithPath: "/tmp/repo"), baseBranch: "main",
                      branch: "flow/1-x", worktree: URL(fileURLWithPath: "/tmp/wt"), inputs: [:])
        let data = try JSONEncoder().encode(run)
        let back = try JSONDecoder().decode(Run.self, from: data)
        #expect(back.flow.notes == notes)
        // A run saved before notes existed still loads.
        let plain = Run(flow: BuiltinFlows.fixGitHubIssue, title: "t", repo: URL(fileURLWithPath: "/tmp/repo"), baseBranch: "main",
                        branch: "flow/1-x", worktree: URL(fileURLWithPath: "/tmp/wt"), inputs: [:])
        #expect(try JSONDecoder().decode(Run.self, from: JSONEncoder().encode(plain)).flow.notes.isEmpty)
    }

    @Test func notesDoNotAffectValidationOrThePlan() throws {
        var flow = BuiltinFlows.fixGitHubIssue
        let plain = try flow.validate()
        flow.notes = notes
        #expect(try flow.validate() == plain)
        // A note with the id of a node, or an overlapping one, changes nothing.
        flow.notes.append(FlowNote(id: "plan", text: "", origin: Point(x: 0, y: 0), width: 1, height: 1, surrounds: true))
        #expect(try flow.validate() == plain)
    }
}
