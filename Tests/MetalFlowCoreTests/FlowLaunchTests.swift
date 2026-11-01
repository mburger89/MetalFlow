import Foundation
import Testing
@testable import MetalFlowCore

private func prompt(_ id: NodeID, _ text: String, inputs: [String: InputBinding] = [:]) -> Node {
    Node(id: id, title: id.rawValue.capitalized, kind: .prompt(PromptConfig(model: "sonnet", prompt: text, candidates: [], allowedTools: [], maxTurns: nil)), position: Point(x: 0, y: 0), inputs: inputs)
}
private func repoNode(_ mode: RepoMode, id: NodeID = "repo") -> Node {
    Node(id: id, title: "Repo", kind: .repo(RepoConfig(mode: mode)), position: Point(x: 0, y: 0))
}
private func input(_ id: NodeID, _ name: String, _ binding: InputBinding = .exposed(default: nil), source: InputSource = .text) -> Node {
    Node(id: id, title: name.capitalized, kind: .flowInput(FlowInputConfig(name: name, source: source, binding: binding)), position: Point(x: 0, y: 0))
}
private let root = URL(fileURLWithPath: "/tmp/r")
private let inRepo = FlowLocation.repo(root: root, file: root.appendingPathComponent(".flows/a.flow"))
private let inLibrary = FlowLocation.library(file: URL(fileURLWithPath: "/tmp/lib/a.flow"))

@Suite struct FlowLaunchTests {
    @Test func validateAcceptsBoundInput() throws {
        let flow = Flow(name: "f", nodes: [prompt("a", "{x}", inputs: ["x": .fixed("v")])], wires: [])
        _ = try flow.validate()
    }

    @Test func unboundInputRejected() {
        let flow = Flow(name: "f", nodes: [prompt("a", "{x}")], wires: [])
        #expect(throws: FlowError.unboundInput("a", "x")) { try flow.validate() }
        #expect(flow.message(for: .unboundInput("a", "x")) == "A: input {x} has no value — wire it, give it a value, or expose it")
        #expect(flow.message(for: .unboundInput("ghost", "x")) == "ghost: input {x} has no value — wire it, give it a value, or expose it")
    }

    @Test func orphanBindingIsIgnored() throws {
        let flow = Flow(name: "f", nodes: [prompt("a", "go {x}", inputs: ["x": .fixed("v"), "old": .exposed(default: "d")]),
                                           prompt("s", "go"), prompt("b", "{y}", inputs: ["z": .fixed("v")]),
                                           repoNode(.fixed(path: "/p"))],
                        wires: [Wire(from: "s", to: "b", input: "y")])
        _ = try flow.validate()
        #expect(try flow.launchFields(location: inLibrary).isEmpty)
        let dropped = flow.droppingOrphanBindings()
        #expect(dropped.node("a")?.inputs == ["x": .fixed("v")])
        #expect(dropped.node("b")?.inputs == [:])
    }

    @Test func inputBoundTwiceRejected() {
        let flow = Flow(name: "f", nodes: [prompt("s", "go"), prompt("a", "{x}", inputs: ["x": .fixed("v")])],
                        wires: [Wire(from: "s", to: "a", input: "x")])
        #expect(throws: FlowError.inputBoundTwice("a", "x")) { try flow.validate() }
    }

    @Test func preplanFlowsStillValidate() throws {
        _ = try BuiltinFlows.fixGitHubIssue.validate()
        let flow = Flow(name: "f", nodes: [prompt("a", "go"), prompt("b", "{x}")], wires: [Wire(from: "a", to: "b", input: "x")])
        _ = try flow.validate()
    }

    @Test func builtinLaunchFields() throws {
        let fields = try BuiltinFlows.fixGitHubIssue.launchFields(location: .builtin)
        #expect(fields == [LaunchField(name: "issue", kind: .githubIssue, defaultValue: nil),
                           LaunchField(name: "repo", kind: .repo, defaultValue: nil)])
        #expect(fields[0].isRequired && fields[1].isRequired)
    }

    @Test func thisRepoRejectedInLibrary() throws {
        let flow = Flow(name: "f", nodes: [repoNode(.thisRepo)], wires: [])
        #expect(throws: LaunchError.thisRepoOutsideRepo) { try flow.launchFields(location: inLibrary) }
        #expect(throws: LaunchError.thisRepoOutsideRepo) { try flow.launchFields(location: .unsaved) }
        #expect(try flow.launchFields(location: inRepo).isEmpty)
    }

    @Test func fixedRepoHasNoField() throws {
        let flow = Flow(name: "f", nodes: [repoNode(.fixed(path: "/x"))], wires: [])
        #expect(try flow.launchFields(location: inLibrary).isEmpty)
    }

    @Test func exposedRepoDefaultPrefills() throws {
        let flow = Flow(name: "f", nodes: [repoNode(.exposed(default: "/d"))], wires: [])
        let f = try flow.launchFields(location: .unsaved)
        #expect(f == [LaunchField(name: "repo", kind: .repo, defaultValue: "/d")])
        #expect(!f[0].isRequired)
    }

    @Test func noRepoNodeRejected() {
        let flow = Flow(name: "f", nodes: [prompt("a", "go")], wires: [])
        #expect(throws: LaunchError.noRepoNode) { try flow.launchFields(location: inRepo) }
    }

    @Test func twoRepoNodesRejected() {
        let flow = Flow(name: "f", nodes: [repoNode(.thisRepo), repoNode(.thisRepo, id: "repo2")], wires: [])
        #expect(throws: LaunchError.multipleRepoNodes) { try flow.launchFields(location: inRepo) }
    }

    @Test func invalidFlowIsWrapped() {
        let flow = Flow(name: "f", nodes: [repoNode(.thisRepo), prompt("a", "{x}")], wires: [])
        #expect(throws: LaunchError.invalid(.unboundInput("a", "x"))) { try flow.launchFields(location: inRepo) }
    }

    @Test func exposedShadowingFlowInputRejected() {
        let flow = Flow(name: "f", nodes: [repoNode(.thisRepo), input("i", "issue"),
                                           prompt("a", "{issue}", inputs: ["issue": .exposed(default: nil)])], wires: [])
        #expect(throws: LaunchError.exposedShadowsFlowInput("a", "issue")) { try flow.launchFields(location: inRepo) }
    }

    @Test func exposedRepoNameReserved() throws {
        let bad = Flow(name: "f", nodes: [repoNode(.thisRepo), prompt("a", "{repo}", inputs: ["repo": .exposed(default: nil)])], wires: [])
        #expect(throws: LaunchError.reservedName("a")) { try bad.launchFields(location: inRepo) }
        let wired = Flow(name: "f", nodes: [repoNode(.thisRepo), prompt("a", "{repo}")], wires: [Wire(from: "repo", to: "a", input: "repo")])
        #expect(try wired.launchFields(location: inRepo).isEmpty)
    }

    @Test func sharedExposedNameIsOneField() throws {
        let b = ["env": InputBinding.exposed(default: "dev")]
        let flow = Flow(name: "f", nodes: [repoNode(.thisRepo), prompt("a", "{env}", inputs: b), prompt("b", "{env}", inputs: b)], wires: [])
        #expect(try flow.launchFields(location: inRepo) == [LaunchField(name: "env", kind: .text, defaultValue: "dev")])
    }

    @Test func conflictingDefaultsRejected() {
        let flow = Flow(name: "f", nodes: [repoNode(.thisRepo),
                                           prompt("a", "{env}", inputs: ["env": .exposed(default: "a")]),
                                           prompt("b", "{env}", inputs: ["env": .exposed(default: "b")])], wires: [])
        #expect(throws: LaunchError.conflictingDefaults("env")) { try flow.launchFields(location: inRepo) }
    }

    @Test func fixedFlowInputHasNoField() throws {
        let flow = Flow(name: "f", nodes: [repoNode(.thisRepo), input("n", "n", .fixed("42"))], wires: [])
        #expect(try flow.launchFields(location: inRepo).isEmpty)
    }

    @Test func fieldsFollowPlanOrderWithRepoLast() throws {
        let flow = Flow(name: "f", nodes: [repoNode(.exposed(default: nil)),
                                           prompt("a", "{p}", inputs: ["p": .exposed(default: nil)]),
                                           input("i", "issue", source: .githubIssue)], wires: [])
        #expect(try flow.launchFields(location: .unsaved).map(\.name) == ["p", "issue", "repo"])
    }

    @Test func launchErrorDescriptions() {
        #expect(LaunchError.noRepoNode.errorDescription == "A flow needs a Repo node")
        #expect(LaunchError.multipleRepoNodes.errorDescription == "A flow can have only one Repo node")
        #expect(LaunchError.thisRepoOutsideRepo.errorDescription == "This repo only works for a flow saved in a repo — choose Fixed or Exposed")
        let flow = Flow(name: "f", nodes: [input("i", "issue")], wires: [])
        #expect(flow.message(for: LaunchError.exposedShadowsFlowInput("a", "issue")) == "{issue} is the Issue input's name — wire it from that node instead")
        #expect(LaunchError.reservedName("a").errorDescription?.isEmpty == false)
        #expect(LaunchError.conflictingDefaults("env").errorDescription?.isEmpty == false)
        #expect(LaunchError.invalid(.cycle(["a"])).errorDescription?.isEmpty == false)
    }

    @Test func locationOfFile() {
        let r = URL(fileURLWithPath: "/tmp/r", isDirectory: true)
        let f = r.appendingPathComponent(".flows/a.flow")
        #expect(FlowLocation.of(file: f) == .repo(root: r, file: f))
        let l = URL(fileURLWithPath: "/tmp/lib/a.flow")
        #expect(FlowLocation.of(file: l) == .library(file: l))
    }
}

@Suite struct FlowLaunchFixedPathTests {
    private func flow(_ path: String) -> Flow {
        Flow(name: "f", nodes: [Node(id: "repo", title: "Repo", kind: .repo(RepoConfig(mode: .fixed(path: path))), position: Point(x: 0, y: 0))], wires: [])
    }

    @Test func emptyOrRelativeFixedPathRejected() {
        for path in ["", "relative/dir"] {
            #expect(throws: LaunchError.fixedRepoPathMissing) { try flow(path).launchFields(location: .builtin) }
        }
        #expect(LaunchError.fixedRepoPathMissing.errorDescription == "Choose the folder for the Fixed repo")
        #expect(flow("").message(for: LaunchError.fixedRepoPathMissing) == "Choose the folder for the Fixed repo")
    }

    @Test func absoluteFixedPathAccepted() throws {
        #expect(try flow("/tmp/r").launchFields(location: .builtin).isEmpty)
    }

    @Test func inputBoundTwiceMessageUsesTitle() {
        let f = Flow(name: "f", nodes: [Node(id: "a", title: "Alpha", kind: .pick, position: Point(x: 0, y: 0))], wires: [])
        #expect(f.message(for: .inputBoundTwice("a", "x")) == "Alpha: input {x} is both wired and set — choose one")
    }
}
