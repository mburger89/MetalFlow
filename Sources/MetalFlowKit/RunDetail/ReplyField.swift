import Foundation
import MetalUI

/// A text field with a Send button beside it, for typing a message to a step's agent. The field's identifier is
/// `<id>.field` and the button's `<id>.send`; Send is disabled while the text is blank.
struct ReplyField: Component {
    let placeholder: String
    let id: String
    let text: Binding<String>
    let send: () -> Void

    var content: some ElementGroup {
        HStack(spacing: Spacing.sm) {
            TextField(placeholder, text: text)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("\(id).field")
            Button("Send") { send() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("\(id).send")
                .disabled(AppModel.trimmed(text.wrappedValue).isEmpty)
        }
    }
}
