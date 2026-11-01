import Foundation
import MetalFlowCore
import MetalUI

/// The control for one launch field, shared by the Dashboard's launch bar and the Studio toolbar: the repo picker (or
/// "No repos yet") with its "Add…" button, or a text field. Ids are `<idPrefix>.field.<name>` and `<idPrefix>.field.repo.add`.
@MainActor struct LaunchFieldControls {
    let model: AppModel
    /// `launch` or `studio`.
    let idPrefix: String
    /// The binding for a field's typed value.
    let value: (LaunchField) -> Binding<String>
    /// Runs when Return is pressed in a text field.
    let submit: @MainActor @Sendable () -> Void
    /// Fixed width of the repo picker, if any.
    var repoWidth: Pixels?
    /// Fixed width of a text field, if any.
    var textWidth: Pixels?
    /// True when the picker and its "Add…" button sit in their own row, false when both are siblings of the caller's row.
    var groupsAddButton = false

    /// The control for `field`; `focus` is bound to a text field (the one ⌘L focuses) and ignored for the repo field.
    @ElementBuilder
    func control(for field: LaunchField, focus: FocusState<Bool>.Binding? = nil) -> some ElementGroup {
        if field.kind == .repo {
            if groupsAddButton {
                HStack(spacing: Spacing.sm) {
                    repoPicker(field)
                    addButton
                }
            } else {
                repoPicker(field)
                addButton
            }
        } else {
            textField(field, focus: focus)
        }
    }

    /// A text field; the frame is applied only when a width is given, so the caller's flexible layout is left alone.
    @ElementBuilder
    private func textField(_ field: LaunchField, focus: FocusState<Bool>.Binding?) -> some ElementGroup {
        let id = "\(idPrefix).field.\(field.name)"
        if let focus, let width = textWidth {
            TextField(field.name, text: value(field)).onSubmit(submit).focused(focus).frame(width: width).accessibilityIdentifier(id)
        } else if let focus {
            TextField(field.name, text: value(field)).onSubmit(submit).focused(focus).accessibilityIdentifier(id)
        } else if let width = textWidth {
            TextField(field.name, text: value(field)).onSubmit(submit).frame(width: width).accessibilityIdentifier(id)
        } else {
            TextField(field.name, text: value(field)).onSubmit(submit).accessibilityIdentifier(id)
        }
    }

    @ElementBuilder
    private func repoPicker(_ field: LaunchField) -> some ElementGroup {
        if model.repos.isEmpty {
            Text("No repos yet").foregroundColor(Palette.muted).accessibilityIdentifier("\(idPrefix).field.repo")
        } else if let width = repoWidth {
            Picker("", selection: value(field)) { repoRows }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: width)
                .accessibilityIdentifier("\(idPrefix).field.repo")
        } else {
            Picker("", selection: value(field)) { repoRows }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityIdentifier("\(idPrefix).field.repo")
        }
    }

    @ElementBuilder
    private var repoRows: some ElementGroup {
        ForEach(model.repos, id: \.path) { url in
            Text(verbatim: url.lastPathComponent).tag(url.path)
        }
    }

    private var addButton: some Element {
        Button("Add\u{2026}") { model.requestAddRepo(.launchField) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("\(idPrefix).field.repo.add")
    }
}
