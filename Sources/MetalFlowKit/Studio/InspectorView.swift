import MetalFlowCore
import Foundation
import MetalUI

/// The models a prompt, judge or candidate can use.
let inspectorModels = ["opus", "sonnet", "haiku"]

/// Picker tag of the "Local model…" entry.
let localModelTag = "local-model"

/// True for `ollama:<name>` or `lmstudio:<name>` with a non-empty name.
func isValidLocalModel(_ name: String) -> Bool { AgentRouter.split(model: name) != nil }

extension FlowDraft {
    /// Edits one field of a node as an undo step named `<field>.<id>`, which coalesces with the previous edit of
    /// that field.
    /// A binding whose placeholder the change removed is kept, inactive, so retyping the placeholder restores it;
    /// saving drops it.
    func editNode(_ id: NodeID, _ field: String, coalescing: Bool = true,
                  _ change: @escaping (inout Node) -> Void) {
        apply("\(field).\(id.rawValue)", coalescing: coalescing) { flow in
            guard let i = flow.nodes.firstIndex(where: { $0.id == id }) else { return }
            change(&flow.nodes[i])
        }
    }

    /// Edits a prompt, judge or review node's prompt configuration.
    func editPrompt(_ id: NodeID, _ field: String, coalescing: Bool = true,
                    _ change: @escaping (inout PromptConfig) -> Void) {
        editNode(id, field, coalescing: coalescing) { node in
            switch node.kind {
            case .prompt(var c): change(&c); node.kind = .prompt(c)
            case .judge(var c): change(&c); node.kind = .judge(c)
            case .review(var c): change(&c.agent); node.kind = .review(c)
            default: break
            }
        }
    }

    /// Edits a shell or gate node's command, or another of its settings when `field` names it.
    func editShell(_ id: NodeID, _ field: String = "command", coalescing: Bool = true,
                   _ change: @escaping (inout ShellConfig) -> Void) {
        editNode(id, field, coalescing: coalescing) { node in
            switch node.kind {
            case .shell(var c): change(&c); node.kind = .shell(c)
            case .gate(var c): change(&c); node.kind = .gate(c)
            default: break
            }
        }
    }

    /// Edits a Review node's configuration.
    func editReview(_ id: NodeID, _ field: String, coalescing: Bool = true, _ change: @escaping (inout ReviewConfig) -> Void) {
        editNode(id, field, coalescing: coalescing) { node in
            if case .review(var c) = node.kind { change(&c); node.kind = .review(c) }
        }
    }

    /// Edits an Open PR node's configuration.
    func editOpenPR(_ id: NodeID, _ field: String, coalescing: Bool = true, _ change: @escaping (inout OpenPRConfig) -> Void) {
        editNode(id, field, coalescing: coalescing) { node in
            if case .openPR(var c) = node.kind { change(&c); node.kind = .openPR(c) }
        }
    }

    /// Whether an Open PR node opens its pull request as a draft; true for any other node.
    func opensDraft(_ id: NodeID) -> Bool {
        if case .openPR(let c)? = flow.node(id)?.kind { return c.draft }
        return true
    }

    /// The fix attempts of a gate or review; 0 for any other node.
    func fixAttempts(_ id: NodeID) -> Int {
        switch flow.node(id)?.kind {
        case .gate(let c)?: return c.fixAttempts
        case .review(let c)?: return c.fixAttempts
        default: return 0
        }
    }

    /// Whether a prompt node feeds the node, directly or through other nodes: someone the gate could send back to fix.
    func hasPromptUpstream(of id: NodeID) -> Bool {
        var seen: Set<NodeID> = [id]
        var stack = [id]
        while let current = stack.popLast() {
            for wire in flow.inputs(of: current) where seen.insert(wire.from).inserted {
                if case .prompt? = flow.node(wire.from)?.kind { return true }
                stack.append(wire.from)
            }
        }
        return false
    }

    /// A prompt, judge or review node's prompt configuration.
    func promptConfig(_ id: NodeID) -> PromptConfig? {
        switch flow.node(id)?.kind {
        case .prompt(let c), .judge(let c): c
        case .review(let c)?: c.agent
        default: nil
        }
    }
}

/// The selected node's settings, a note's text, or a count when several things are selected.
struct InspectorView: Component {
    let model: AppModel
    let draft: FlowDraft
    /// The known repos the Repo node's path picker offers.
    var repos: [URL] = []

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let id = draft.selection, let node = draft.flow.node(id) {
                NodeInspector(model: model, draft: draft, node: node, repos: repos)
            } else if draft.canvasSelection.count > 1 {
                Text(verbatim: "\(draft.canvasSelection.count) selected").font(size: 13).foregroundColor(Palette.text)
                    .accessibilityIdentifier("inspector.selectionCount")
                Button("Delete") { draft.deleteSelection() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("inspector.deleteSelection")
            } else if draft.canvasSelection.count == 1, let id = draft.canvasSelection.notes.first,
                      let note = draft.flow.notes.first(where: { $0.id == id }) {
                Text(verbatim: "Note").font(size: 11).foregroundColor(Palette.muted)
                    .accessibilityIdentifier("inspector.note")
                Text(verbatim: note.text).font(size: 13).foregroundColor(Palette.text)
                    .accessibilityIdentifier("inspector.noteText")
                Text(verbatim: "Double-click the note to edit it. Delete removes it.")
                    .font(size: 12).foregroundColor(Palette.muted)
            } else if let wire = draft.selectedWire {
                Text(verbatim: "Wire").font(size: 11).foregroundColor(Palette.muted)
                Text(verbatim: "\(wire.from.rawValue) → \(wire.to.rawValue) as {\(wire.input)}")
                    .font(size: 13).foregroundColor(Palette.text)
                    .accessibilityIdentifier("inspector.selectedWire")
                Text(verbatim: "Rename the input under Incoming wires of the target node. Delete removes the wire.")
                    .font(size: 12).foregroundColor(Palette.muted)
            } else {
                Text(verbatim: "Select a node to see its settings.").font(size: 12).foregroundColor(Palette.muted)
                    .accessibilityIdentifier("inspector.empty")
            }
        }
        .padding(insets(top: 12, right: 14, bottom: 12, left: 14))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .background(Palette.panel)
    }

    /// One tool per line: each trimmed, empty lines dropped.
    static func parseTools(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// The fields of one node.
struct NodeInspector: Component {
    let model: AppModel
    let draft: FlowDraft
    let node: Node
    var repos: [URL] = []

    var content: some ElementGroup {
        let id = node.id
        let draft = draft
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(verbatim: node.kindLabel).font(size: 11).foregroundColor(Palette.muted)
                label("Title")
                TextField("Title", text: Binding(
                    get: { draft.flow.node(id)?.title ?? "" },
                    set: { value in draft.editNode(id, "title") { $0.title = value } }))
                    .accessibilityIdentifier("inspector.title")
                label("Id")
                Text(verbatim: id.rawValue).font(Theme.mono(12)).foregroundColor(Palette.muted)
                    .accessibilityIdentifier("inspector.id")
                switch node.kind {
                case .flowInput: FlowInputFields(draft: draft, id: id)
                case .repo: RepoFields(model: model, draft: draft, id: id, repos: repos)
                case .prompt, .judge: PromptFields(draft: draft, id: id)
                case .review:
                    PromptFields(draft: draft, id: id)
                    FixAttemptsFields(draft: draft, id: id)
                case .shell, .gate:
                    label("Command")
                    TextField("Command", text: Binding(
                        get: { Self.command(draft, id) },
                        set: { value in draft.editShell(id) { $0.command = value } }))
                        .font(family: "Menlo", size: 12)
                        .accessibilityIdentifier("inspector.command")
                    if case .gate = node.kind { FixAttemptsFields(draft: draft, id: id) }
                case .pick:
                    Text(verbatim: "Waits for you to pick a candidate.").font(size: 12).foregroundColor(Palette.muted)
                case .openPR:
                    Toggle("Draft", isOn: Binding(
                        get: { draft.opensDraft(id) },
                        set: { value in draft.editOpenPR(id, "draft", coalescing: false) { $0.draft = value } }))
                        .accessibilityIdentifier("inspector.openpr.draft")
                    Text(verbatim: "Pushes the picked branch and opens a pull request instead of merging.")
                        .font(size: 12).foregroundColor(Palette.muted)
                }
                IncomingWires(draft: draft, id: id)
                if node.acceptsInputs { InputBindings(draft: draft, id: id) }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func command(_ draft: FlowDraft, _ id: NodeID) -> String {
        switch draft.flow.node(id)?.kind {
        case .shell(let c), .gate(let c): c.command
        default: ""
        }
    }

    func label(_ text: String) -> some Element {
        Text(verbatim: text).font(size: 11).foregroundColor(Palette.muted)
    }
}

/// How many times a failing gate, or a review that finds problems, may send its agent back to fix the code.
struct FixAttemptsFields: Component {
    let draft: FlowDraft
    let id: NodeID

    /// The most fix attempts a gate or review can be given.
    static let maxAttempts = 5

    var content: some ElementGroup {
        let draft = draft, id = id
        let isReview: Bool = { if case .review? = draft.flow.node(id)?.kind { return true } else { return false } }()
        let kind = isReview ? "review" : "gate"
        Text(verbatim: "Fix attempts").font(size: 11).foregroundColor(Palette.muted)
            .accessibilityIdentifier("inspector.fixAttempts.label")
        Picker("", selection: Binding(
            get: { draft.fixAttempts(id) },
            set: { value in
                if isReview {
                    draft.editReview(id, "fixAttempts", coalescing: false) { $0.fixAttempts = value }
                } else {
                    draft.editShell(id, "fixAttempts", coalescing: false) { $0.fixAttempts = value }
                }
            })) {
            ForEach(Array(0...Self.maxAttempts), id: \.self) { Text(verbatim: "\($0)").tag($0) }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityIdentifier("inspector.\(kind).fixAttempts")
        if isReview {
            Text(verbatim: "Sends the requested changes back to the agent up to this many times.")
                .font(size: 12).foregroundColor(Palette.muted)
                .accessibilityIdentifier("inspector.review.fixHint")
            Text(verbatim: "{diff} is filled in with the candidate's changes.")
                .font(size: 12).foregroundColor(Palette.muted)
                .accessibilityIdentifier("inspector.review.diffHint")
        } else if !draft.hasPromptUpstream(of: id) {
            Text(verbatim: "Needs a Prompt node feeding this gate.").font(size: 12).foregroundColor(Palette.muted)
                .accessibilityIdentifier("inspector.gate.fixHint")
        }
    }
}

extension Node {
    /// Whether the node has placeholders to bind: prompt, judge, review, shell and gate.
    var acceptsInputs: Bool {
        switch kind {
        case .prompt, .judge, .shell, .gate, .review: true
        default: false
        }
    }
}

/// Where a node input's value comes from.
enum InputMode: Hashable {
    case wire, value, exposed

    init(_ binding: InputBinding?) {
        switch binding {
        case nil: self = .wire
        case .fixed?: self = .value
        case .exposed?: self = .exposed
        }
    }
}

extension FlowDraft {
    /// Switches how `name` of node `id` gets its value, as one undo step. Value and Exposed drop any wire into
    /// that input; Wire drops the binding.
    func setInputMode(_ id: NodeID, _ name: String, _ mode: InputMode) {
        apply("inputMode.\(id.rawValue).\(name)", coalescing: false) { flow in
            guard let i = flow.nodes.firstIndex(where: { $0.id == id }) else { return }
            switch (mode, flow.nodes[i].inputs[name]) {
            case (.wire, _): flow.nodes[i].inputs[name] = nil
            case (.value, .fixed?), (.exposed, .exposed?): return
            case (.value, _):
                flow.wires.removeAll { $0.to == id && $0.input == name }
                flow.nodes[i].inputs[name] = .fixed("")
            case (.exposed, _):
                flow.wires.removeAll { $0.to == id && $0.input == name }
                flow.nodes[i].inputs[name] = .exposed(default: nil)
            }
        }
    }
}

/// One row per placeholder of a node's prompt or command: Wire, Value or Exposed.
struct InputBindings: Component {
    let draft: FlowDraft
    let id: NodeID

    var content: some ElementGroup {
        let names = draft.flow.inputNames(of: id)
        let draft = draft, id = id
        if !names.isEmpty {
            Text(verbatim: "Inputs").font(size: 11).foregroundColor(Palette.muted)
            ForEach(names, id: \.self) { name in
                InputRow(draft: draft, id: id, name: name)
            }
        }
    }
}

/// The mode picker and the mode's field for one input.
struct InputRow: Component {
    let draft: FlowDraft
    let id: NodeID
    let name: String

    var content: some ElementGroup {
        let draft = draft, id = id, name = name
        let binding = draft.flow.node(id)?.inputs[name]
        let source = draft.flow.inputs(of: id).first { $0.input == name }
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(verbatim: "{\(name)}").font(Theme.mono(12)).foregroundColor(Palette.body)
            Picker("", selection: Binding(
                get: { InputMode(draft.flow.node(id)?.inputs[name]) },
                set: { draft.setInputMode(id, name, $0) })) {
                Text("Wire").accessibilityIdentifier("inspector.input.\(name).mode.wire").tag(InputMode.wire)
                Text("Value").accessibilityIdentifier("inspector.input.\(name).mode.value").tag(InputMode.value)
                Text("Exposed").accessibilityIdentifier("inspector.input.\(name).mode.exposed").tag(InputMode.exposed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("inspector.input.\(name)")
            switch binding {
            case nil:
                if let source {
                    Text(verbatim: draft.flow.node(source.from)?.title ?? source.from.rawValue)
                        .font(size: 12).foregroundColor(Palette.text)
                        .accessibilityIdentifier("inspector.input.\(name).source")
                } else {
                    Text(verbatim: "not wired").font(size: 12).foregroundColor(Palette.bad)
                        .accessibilityIdentifier("inspector.input.\(name).source")
                }
            case .fixed?:
                TextField("Value", text: Binding(
                    get: { if case .fixed(let v)? = draft.flow.node(id)?.inputs[name] { v } else { "" } },
                    set: { value in draft.editNode(id, "input.\(name)") { $0.inputs[name] = .fixed(value) } }))
                    .accessibilityIdentifier("inspector.input.\(name).value")
            case .exposed?:
                TextField("no default (required)", text: Binding(
                    get: { if case .exposed(let d)? = draft.flow.node(id)?.inputs[name] { d ?? "" } else { "" } },
                    set: { value in
                        draft.editNode(id, "input.\(name)") { $0.inputs[name] = .exposed(default: value.isEmpty ? nil : value) }
                    }))
                    .accessibilityIdentifier("inspector.input.\(name).default")
            }
        }
    }
}

/// Mode and path of the Repo node.
struct RepoFields: Component {
    let model: AppModel
    let draft: FlowDraft
    let id: NodeID
    let repos: [URL]

    enum Choice: Hashable { case thisRepo, fixed, exposed }

    static func mode(_ draft: FlowDraft, _ id: NodeID) -> RepoMode {
        if case .repo(let c)? = draft.flow.node(id)?.kind { return c.mode }
        return .exposed(default: nil)
    }

    static func path(_ mode: RepoMode) -> String? {
        switch mode {
        case .thisRepo: nil
        case .fixed(let p): p
        case .exposed(let d): d
        }
    }

    var content: some ElementGroup {
        let draft = draft, id = id, repos = repos
        let mode = Self.mode(draft, id)
        Text(verbatim: "Mode").font(size: 11).foregroundColor(Palette.muted)
        Picker("", selection: Binding(
            get: {
                switch Self.mode(draft, id) {
                case .thisRepo: Choice.thisRepo
                case .fixed: Choice.fixed
                case .exposed: Choice.exposed
                }
            },
            set: { choice in
                let carried = Self.path(Self.mode(draft, id))
                let next: RepoMode = switch choice {
                case .thisRepo: .thisRepo
                case .fixed: .fixed(path: carried ?? repos.first?.path ?? "")
                case .exposed: .exposed(default: carried)
                }
                draft.editNode(id, "repoMode", coalescing: false) { $0.kind = .repo(RepoConfig(mode: next)) }
            })) {
            Text(verbatim: "This repo").tag(Choice.thisRepo)
            Text(verbatim: "Fixed").tag(Choice.fixed)
            Text(verbatim: "Exposed").tag(Choice.exposed)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityIdentifier("inspector.repo.mode")
        if mode != .thisRepo {
            Text(verbatim: { if case .fixed = mode { "Path" } else { "Default path" } }())
                .font(size: 11).foregroundColor(Palette.muted)
            if !repos.isEmpty {
                Picker("", selection: Binding(
                    get: { Self.path(Self.mode(draft, id)) ?? "" },
                    set: { value in Self.setPath(draft, id, value, coalescing: false) })) {
                    ForEach(repos, id: \.path) { url in Text(verbatim: url.lastPathComponent).tag(url.path) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityIdentifier("inspector.repo.path")
            }
            TextField("/path/to/repo", text: Binding(
                get: { Self.path(Self.mode(draft, id)) ?? "" },
                set: { value in Self.setPath(draft, id, value, coalescing: true) }))
                .font(family: "Menlo", size: 12)
                .accessibilityIdentifier("inspector.repo.pathField")
            Button("Choose folder\u{2026}") { model.requestAddRepo(.repoNode(id)) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("inspector.repo.add")
        } else {
            Text(verbatim: "The repo this flow file lives in.").font(size: 12).foregroundColor(Palette.muted)
        }
    }

    static func setPath(_ draft: FlowDraft, _ id: NodeID, _ value: String, coalescing: Bool) {
        draft.editNode(id, "repoPath", coalescing: coalescing) { node in
            guard case .repo(var c) = node.kind else { return }
            switch c.mode {
            case .thisRepo: return
            case .fixed: c.mode = .fixed(path: value)
            case .exposed: c.mode = .exposed(default: value.isEmpty ? nil : value)
            }
            node.kind = .repo(c)
        }
    }
}

/// Name and source of a flow input.
struct FlowInputFields: Component {
    let draft: FlowDraft
    let id: NodeID

    var content: some ElementGroup {
        let draft = draft, id = id
        Text(verbatim: "Name").font(size: 11).foregroundColor(Palette.muted)
        TextField("Name", text: Binding(
            get: { Self.config(draft, id)?.name ?? "" },
            set: { value in draft.editNode(id, "inputName") { Self.update(&$0) { $0.name = value } } }))
            .accessibilityIdentifier("inspector.inputName")
        Text(verbatim: "Source").font(size: 11).foregroundColor(Palette.muted)
        Picker("", selection: Binding(
            get: { Self.config(draft, id)?.source ?? .githubIssue },
            set: { value in draft.editNode(id, "inputSource", coalescing: false) { Self.update(&$0) { $0.source = value } } })) {
            Text(verbatim: "GitHub issue").tag(InputSource.githubIssue)
            Text(verbatim: "Text").tag(InputSource.text)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityIdentifier("inspector.inputSource")
        Text(verbatim: "Value").font(size: 11).foregroundColor(Palette.muted)
        Picker("", selection: Binding(
            get: { if case .fixed? = Self.config(draft, id)?.binding { Mode.fixed } else { Mode.exposed } },
            set: { mode in
                draft.editNode(id, "inputBinding", coalescing: false) {
                    Self.update(&$0) { $0.binding = mode == .fixed ? .fixed("") : .exposed(default: nil) }
                }
            })) {
            Text("Fixed").accessibilityIdentifier("inspector.flowInput.mode.fixed").tag(Mode.fixed)
            Text("Exposed").accessibilityIdentifier("inspector.flowInput.mode.exposed").tag(Mode.exposed)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("inspector.flowInput.mode")
        switch Self.config(draft, id)?.binding {
        case .fixed?:
            TextField("Value", text: Binding(
                get: { if case .fixed(let v)? = Self.config(draft, id)?.binding { v } else { "" } },
                set: { value in draft.editNode(id, "inputValue") { Self.update(&$0) { $0.binding = .fixed(value) } } }))
                .accessibilityIdentifier("inspector.flowInput.value")
        default:
            TextField("no default (required)", text: Binding(
                get: { if case .exposed(let d)? = Self.config(draft, id)?.binding { d ?? "" } else { "" } },
                set: { value in
                    draft.editNode(id, "inputValue") { Self.update(&$0) { $0.binding = .exposed(default: value.isEmpty ? nil : value) } }
                }))
                .accessibilityIdentifier("inspector.flowInput.value")
        }
    }

    enum Mode: Hashable { case fixed, exposed }

    static func config(_ draft: FlowDraft, _ id: NodeID) -> FlowInputConfig? {
        if case .flowInput(let c) = draft.flow.node(id)?.kind { return c }
        return nil
    }

    static func update(_ node: inout Node, _ change: (inout FlowInputConfig) -> Void) {
        if case .flowInput(var c) = node.kind { change(&c); node.kind = .flowInput(c) }
    }
}

/// Model, candidates (not for a review), prompt, tools and max turns of a prompt, judge or review.
struct PromptFields: Component {
    let draft: FlowDraft
    let id: NodeID

    var content: some ElementGroup {
        let draft = draft, id = id
        let isReview: Bool = { if case .review? = draft.flow.node(id)?.kind { return true } else { return false } }()
        let config = draft.promptConfig(id) ?? PromptConfig(model: "sonnet", prompt: "", candidates: [], allowedTools: [], maxTurns: nil)
        Text(verbatim: "Model").font(size: 11).foregroundColor(Palette.muted)
        modelPicker(selection: Binding(
            get: {
                let model = draft.promptConfig(id)?.model ?? "sonnet"
                if draft.localModelBuffer?.node == id || isValidLocalModel(model) { return localModelTag }
                return model
            },
            set: { value in
                if value == localModelTag {
                    let model = draft.promptConfig(id)?.model ?? ""
                    draft.localModelBuffer = (id, isValidLocalModel(model) ? model : "")
                } else {
                    draft.localModelBuffer = nil
                    draft.editPrompt(id, "model", coalescing: false) { $0.model = value }
                }
            }), identifier: "inspector.model", allowsLocal: true)
        if draft.localModelBuffer?.node == id || isValidLocalModel(config.model) {
            let typed = draft.localModelBuffer?.node == id ? draft.localModelBuffer!.text : config.model
            TextField("ollama:qwen2.5-coder:7b", text: Binding(
                get: { typed },
                set: { value in
                    draft.localModelBuffer = (id, value)
                    if isValidLocalModel(value) { draft.editPrompt(id, "model") { $0.model = value } }
                }))
                .accessibilityIdentifier("inspector.localModel.field")
            if !isValidLocalModel(typed) {
                Text(verbatim: "Use ollama:<name> or lmstudio:<name>").font(size: 12).foregroundColor(Palette.bad)
            }
        }
        if !isReview {
            Stepper("Candidates: \(config.candidateCount)", value: Binding(
                get: { draft.promptConfig(id)?.candidateCount ?? 1 },
                set: { value in draft.editPrompt(id, "candidates", coalescing: false) { $0.setCandidateCount(value) } }), in: 1...PromptConfig.maxCandidates)
                .accessibilityIdentifier("inspector.candidates")
        }
        if config.candidates.count > 1 {
            ForEach(Array(config.candidates.indices), id: \.self) { index in
                HStack(spacing: Spacing.sm) {
                    Text(verbatim: "Candidate \(index + 1)").font(size: 12).foregroundColor(Palette.muted)
                    modelPicker(selection: Binding(
                        get: { draft.promptConfig(id)?.candidates[safe: index] ?? "sonnet" },
                        set: { value in
                            draft.editPrompt(id, "candidate\(index)", coalescing: false) { if $0.candidates.indices.contains(index) { $0.candidates[index] = value } }
                        }), identifier: "inspector.candidate.\(index)")
                }
            }
        }
        Text(verbatim: "Prompt").font(size: 11).foregroundColor(Palette.muted)
        TextEditor(text: Binding(
            get: { draft.promptConfig(id)?.prompt ?? "" },
            set: { value in draft.editPrompt(id, "prompt") { $0.prompt = value } }))
            .font(family: "Menlo", size: 12)
            .frame(height: Pixels(180))
            .accessibilityIdentifier("inspector.prompt")
        Text(verbatim: "Allowed tools (one per line)").font(size: 11).foregroundColor(Palette.muted)
        TextEditor(text: Binding(
            get: { Self.toolsText(draft, id) },
            set: { value in
                draft.toolsBuffer = (id, value)
                draft.editPrompt(id, "tools") { $0.allowedTools = InspectorView.parseTools(value) }
            }))
            .font(family: "Menlo", size: 12)
            .frame(height: Pixels(90))
            .accessibilityIdentifier("inspector.tools")
        Text(verbatim: "Max turns").font(size: 11).foregroundColor(Palette.muted)
        TextField("No limit", text: Binding(
            get: { draft.promptConfig(id)?.maxTurns.map(String.init) ?? "" },
            set: { value in
                let digits = value.filter { $0.isASCII && $0.isNumber }
                draft.editPrompt(id, "maxTurns") { $0.maxTurns = Int(digits) }
            }))
            .accessibilityIdentifier("inspector.maxTurns")
    }

    /// The tools text as typed, while it still parses to the node's tools (so a trailing newline survives typing).
    static func toolsText(_ draft: FlowDraft, _ id: NodeID) -> String {
        let tools = draft.promptConfig(id)?.allowedTools ?? []
        if let buffer = draft.toolsBuffer, buffer.node == id, InspectorView.parseTools(buffer.text) == tools {
            return buffer.text
        }
        return tools.joined(separator: "\n")
    }

    func modelPicker(selection: Binding<String>, identifier: String, allowsLocal: Bool = false) -> some Element {
        Picker("", selection: selection) {
            ForEach(inspectorModels, id: \.self) { Text(verbatim: $0).tag($0) }
            if allowsLocal {
                Text(verbatim: "Local model…").accessibilityIdentifier("inspector.localModel").tag(localModelTag)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityIdentifier(identifier)
    }
}

extension Array {
    /// The element at `index`, or nil when out of range.
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The wires feeding a node, each with an editable input name.
struct IncomingWires: Component {
    let draft: FlowDraft
    let id: NodeID

    var content: some ElementGroup {
        let wires = draft.flow.inputs(of: id)
        let draft = draft, id = id
        if !wires.isEmpty {
            Text(verbatim: "Incoming wires").font(size: 11).foregroundColor(Palette.muted)
            // Keyed by position so a wire's field keeps its identity (and focus) while its name is typed.
            ForEach(Array(wires.indices), id: \.self) { index in
                HStack(spacing: Spacing.sm) {
                    Text(verbatim: wires[index].from.rawValue).font(size: 12).foregroundColor(Palette.body)
                        .frame(width: Pixels(80), alignment: .leading)
                        .lineLimit(1)
                    TextField("input", text: Binding(
                        get: { draft.flow.inputs(of: id)[safe: index]?.input ?? "" },
                        set: { value in Self.rename(draft, id, index, value) }))
                        .font(family: "Menlo", size: 12)
                        .accessibilityIdentifier("inspector.wire.\(wires[index].from.rawValue).\(wires[index].input)")
                }
            }
        }
    }

    /// Renames the `index`th wire into `id`.
    static func rename(_ draft: FlowDraft, _ id: NodeID, _ index: Int, _ value: String) {
        draft.edit("wire.\(id.rawValue).\(index)") { flow in
            let positions = flow.wires.indices.filter { flow.wires[$0].to == id }
            if positions.indices.contains(index) { flow.wires[positions[index]].input = value }
        }
        if let selected = draft.selectedWire, !draft.flow.wires.contains(selected) { draft.selectedWire = nil }
    }
}
