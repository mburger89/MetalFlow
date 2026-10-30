import MetalFlowCore
import MetalUI

/// The models a prompt, judge or candidate can use.
let inspectorModels = ["opus", "sonnet", "haiku"]

extension FlowDraft {
    /// Edits one field of a node as an undo step named `<field>.<id>`, which coalesces with the previous edit of
    /// that field.
    func editNode(_ id: NodeID, _ field: String, coalescing: Bool = true, _ change: @escaping (inout Node) -> Void) {
        apply("\(field).\(id.rawValue)", coalescing: coalescing) { flow in
            if let i = flow.nodes.firstIndex(where: { $0.id == id }) { change(&flow.nodes[i]) }
        }
    }

    /// Edits a prompt or judge node's configuration.
    func editPrompt(_ id: NodeID, _ field: String, coalescing: Bool = true,
                    _ change: @escaping (inout PromptConfig) -> Void) {
        editNode(id, field, coalescing: coalescing) { node in
            switch node.kind {
            case .prompt(var c): change(&c); node.kind = .prompt(c)
            case .judge(var c): change(&c); node.kind = .judge(c)
            default: break
            }
        }
    }

    /// Edits a shell or gate node's command.
    func editShell(_ id: NodeID, _ change: @escaping (inout ShellConfig) -> Void) {
        editNode(id, "command") { node in
            switch node.kind {
            case .shell(var c): change(&c); node.kind = .shell(c)
            case .gate(var c): change(&c); node.kind = .gate(c)
            default: break
            }
        }
    }

    /// A prompt or judge node's configuration.
    func promptConfig(_ id: NodeID) -> PromptConfig? {
        switch flow.node(id)?.kind {
        case .prompt(let c), .judge(let c): c
        default: nil
        }
    }
}

/// The selected node's or wire's settings.
struct InspectorView: Component {
    let draft: FlowDraft

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let id = draft.selection, let node = draft.flow.node(id) {
                NodeInspector(draft: draft, node: node)
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
            Spacer()
        }
        .padding(insets(top: 12, right: 14, bottom: 12, left: 14))
        .frame(width: Pixels(320), alignment: .topLeading)
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
    let draft: FlowDraft
    let node: Node

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
                case .repo:
                    Text(verbatim: "The run's worktree.").font(size: 12).foregroundColor(Palette.muted)
                case .prompt, .judge: PromptFields(draft: draft, id: id)
                case .shell, .gate:
                    label("Command")
                    TextField("Command", text: Binding(
                        get: { Self.command(draft, id) },
                        set: { value in draft.editShell(id) { $0.command = value } }))
                        .font(family: "Menlo", size: 12)
                        .accessibilityIdentifier("inspector.command")
                case .pick:
                    Text(verbatim: "Waits for you to pick a candidate.").font(size: 12).foregroundColor(Palette.muted)
                }
                IncomingWires(draft: draft, id: id)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
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
        .accessibilityIdentifier("inspector.inputSource")
    }

    static func config(_ draft: FlowDraft, _ id: NodeID) -> FlowInputConfig? {
        if case .flowInput(let c) = draft.flow.node(id)?.kind { return c }
        return nil
    }

    static func update(_ node: inout Node, _ change: (inout FlowInputConfig) -> Void) {
        if case .flowInput(var c) = node.kind { change(&c); node.kind = .flowInput(c) }
    }
}

/// Model, candidates, prompt, tools and max turns of a prompt or judge.
struct PromptFields: Component {
    let draft: FlowDraft
    let id: NodeID

    var content: some ElementGroup {
        let draft = draft, id = id
        let config = draft.promptConfig(id) ?? PromptConfig(model: "sonnet", prompt: "", candidates: [], allowedTools: [], maxTurns: nil)
        Text(verbatim: "Model").font(size: 11).foregroundColor(Palette.muted)
        modelPicker(selection: Binding(
            get: { draft.promptConfig(id)?.model ?? "sonnet" },
            set: { value in draft.editPrompt(id, "model", coalescing: false) { $0.model = value } }), identifier: "inspector.model")
        Stepper("Candidates: \(config.candidateCount)", value: Binding(
            get: { draft.promptConfig(id)?.candidateCount ?? 1 },
            set: { value in draft.editPrompt(id, "candidates", coalescing: false) { $0.setCandidateCount(value) } }), in: 1...PromptConfig.maxCandidates)
            .accessibilityIdentifier("inspector.candidates")
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

    func modelPicker(selection: Binding<String>, identifier: String) -> some Element {
        Picker("", selection: selection) {
            ForEach(inspectorModels, id: \.self) { Text(verbatim: $0).tag($0) }
        }
        .pickerStyle(.menu)
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
