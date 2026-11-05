import MetalUI

/// A two-segment Edit / Preview control. `true` means Preview.
public struct MarkdownPreviewToggle: Component {
    let isPreview: Binding<Bool>

    public init(isPreview: Binding<Bool>) { self.isPreview = isPreview }

    public var content: some ElementGroup {
        Picker("Mode", selection: isPreview) {
            Text("Edit").accessibilityIdentifier("markdown.edit").tag(false)
            Text("Preview").accessibilityIdentifier("markdown.preview").tag(true)
        }
        .pickerStyle(.segmented)
        .frame(width: Pixels(160))
    }
}
