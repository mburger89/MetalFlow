import Foundation
import MetalUI

/// Flow, issue and repo pickers with the Launch button, plus an "Add repo..." path field.
struct LaunchBar: Component {
    let model: AppModel

    var content: some ElementGroup {
        let form = model.launchForm
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .bottom, spacing: Spacing.md) {
                labelled("Flow") {
                    if model.repoFlows.isEmpty {
                        Text("No flows in this repo").foregroundColor(Palette.muted)
                            .accessibilityIdentifier("launch.flow")
                    } else {
                        Picker("Flow", selection: Binding(
                            get: { model.launchForm.flow ?? model.repoFlows[0] },
                            set: { model.selectFlow($0) })) {
                            ForEach(model.repoFlows, id: \.self) { url in
                                Text(verbatim: url.deletingPathExtension().lastPathComponent).tag(url)
                            }
                        }
                        .accessibilityIdentifier("launch.flow")
                    }
                }
                .frame(maxWidth: .infinity)
                labelled("Issue") {
                    TextField("#68 or issue URL", text: Binding(
                        get: { model.launchForm.issue }, set: { model.launchForm.issue = $0 }))
                        .onSubmit { launch() }
                        .accessibilityIdentifier("launch.issue")
                }
                .frame(maxWidth: .infinity)
                .frame(minWidth: Pixels(260))
                labelled("Repo") {
                    if model.repos.isEmpty {
                        Text("No repos yet").foregroundColor(Palette.muted).accessibilityIdentifier("launch.repo")
                    } else {
                        Picker("Repo", selection: Binding(
                            get: { model.launchForm.repo ?? model.repos[0] },
                            set: { model.selectRepo($0) })) {
                            ForEach(model.repos, id: \.self) { url in
                                Text(verbatim: url.lastPathComponent).tag(url)
                            }
                        }
                        .accessibilityIdentifier("launch.repo")
                    }
                }
                .frame(maxWidth: .infinity)
                Button("Launch run") { launch() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("launch.go")
                    .disabled(!model.canLaunch)
            }
            HStack(spacing: Spacing.sm) {
                TextField("Add repo... (path to a git repo)", text: Binding(
                    get: { model.launchForm.newRepoPath }, set: { model.launchForm.newRepoPath = $0 }))
                    .onSubmit { addRepo() }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("launch.addrepo")
                Button("Add") { addRepo() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("launch.addrepo.go")
                    .disabled(form.newRepoPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Edges(all: Spacing.md))
        .background(Color(Hsla.rgb(0x171a1f)))
        .cornerRadius(14)
        .border(Color(Hsla.rgb(0x2f343c)), width: 1)
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

    private func addRepo() {
        let model = model
        let path = model.launchForm.newRepoPath
        Task { await model.addRepo(path: path) }
    }
}
