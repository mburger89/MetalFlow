import Foundation
import MetalFlowCore
import MetalUI

/// The flow picker, one control per launch field and the Launch button, plus an "Add repo..." button.
struct LaunchBar: Component {
    let model: AppModel
    @FocusState var issueFocused: Bool

    var content: some ElementGroup {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .bottom, spacing: Spacing.md) {
                labelled("Flow") {
                    if model.catalog.isEmpty {
                        Text("No flows").foregroundColor(Palette.muted).accessibilityIdentifier("launch.flow")
                    } else {
                        Picker("", selection: Binding(
                            get: { model.launchForm.flow ?? model.catalog[0].id },
                            set: { id in let model = model; Task { await model.selectFlow(id) } })) {
                            ForEach(model.catalog, id: \.id) { entry in
                                Text(verbatim: Self.title(of: entry)).tag(entry.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("launch.flow")
                    }
                }
                .frame(maxWidth: .infinity)
                ForEach(Array(model.launchFields.enumerated()), id: \.element.name) { index, field in
                    labelled(field.name) { control(for: field, isFirstText: index == model.launchFields.firstIndex { $0.kind != .repo }) }
                        .frame(maxWidth: .infinity)
                        .frame(minWidth: Pixels(field.kind == .repo ? 140 : 200))
                }
                if let resolved = model.launchResolvedRepo {
                    labelled("Repo") {
                        Text(verbatim: resolved).foregroundColor(Palette.text)
                            .accessibilityIdentifier("launch.repo.resolved")
                    }
                }
                Button("Launch run") { launch() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("launch.go")
                    .disabled(!model.canLaunch)
            }
            if let error = model.launchError {
                Text(verbatim: error).font(size: 12).foregroundColor(Palette.bad)
                    .accessibilityIdentifier("launch.error")
            }
            Button("Add repo\u{2026}") { model.requestAddRepo(.dashboard) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("launch.addrepo")
        }
        .task(id: model.launchFocusRequested) {
            // ⌘L: take the request, then focus the issue field.
            guard model.launchFocusRequested else { return }
            model.launchFocusRequested = false
            issueFocused = true
        }
        .padding(Edges(all: Spacing.md))
        .background(Color(Hsla.rgb(0x171a1f)))
        .cornerRadius(14)
        .border(Color(Hsla.rgb(0x2f343c)), width: 1)
    }

    /// "name — Library", "name — <repo folder>" or "name — Built-in".
    static func title(of entry: FlowEntry) -> String {
        switch entry.location {
        case .builtin: "\(entry.name) \u{2014} Built-in"
        case .library: "\(entry.name) \u{2014} Library"
        case .repo(let root, _): "\(entry.name) \u{2014} \(root.lastPathComponent)"
        case .unsaved: entry.name
        }
    }

    @ElementBuilder
    private func control(for field: LaunchField, isFirstText: Bool) -> some ElementGroup {
        if field.kind == .repo {
            if model.repos.isEmpty {
                HStack(spacing: Spacing.sm) {
                    Text("No repos yet").foregroundColor(Palette.muted).accessibilityIdentifier("launch.field.repo")
                    addButton
                }
            } else {
                HStack(spacing: Spacing.sm) {
                    Picker("", selection: Binding(
                        get: { model.launchForm.values["repo"] ?? "" },
                        set: { model.launchForm.values["repo"] = $0 })) {
                        ForEach(model.repos, id: \.path) { url in
                            Text(verbatim: url.lastPathComponent).tag(url.path)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("launch.field.repo")
                    addButton
                }
            }
        } else if isFirstText {
            TextField(field.name, text: textBinding(field))
                .onSubmit { launch() }
                .focused($issueFocused)
                .accessibilityIdentifier("launch.field.\(field.name)")
        } else {
            TextField(field.name, text: textBinding(field))
                .onSubmit { launch() }
                .accessibilityIdentifier("launch.field.\(field.name)")
        }
    }

    private var addButton: some Element {
        Button("Add\u{2026}") { model.requestAddRepo(.launchField) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("launch.field.repo.add")
    }

    private func textBinding(_ field: LaunchField) -> Binding<String> {
        Binding(get: { model.launchForm.values[field.name] ?? "" }, set: { model.launchForm.values[field.name] = $0 })
    }

    @ElementBuilder
    private func labelled<Content: ElementGroup>(_ title: String, @ElementBuilder content: () -> Content) -> some ElementGroup {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(size: 12).foregroundColor(Palette.muted)
            content()
        }
    }

    private func launch() {
        let model = model
        Task { await model.launchFromForm() }
    }
}
