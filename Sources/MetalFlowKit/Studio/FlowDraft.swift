import Foundation
import MetalFlowCore
import MetalUI
import Observation

/// A flow being viewed or edited in the Studio: the flow, where it lives, its validation, undo history,
/// the canvas view and the selection.
@Observable @MainActor
public final class FlowDraft {
    /// The most undo steps kept.
    public static let historyLimit = 100

    /// The flow as edited.
    public private(set) var flow: Flow {
        didSet { validation = Self.validate(flow) }
    }
    /// The file it was loaded from or saved to; nil for a flow not yet saved.
    public var url: URL?
    /// The repository runs of this flow launch in and unsaved flows are saved into.
    public var repo: URL {
        didSet { if repo != oldValue { onRetarget?() } }
    }
    /// Called when the repo changes.
    @ObservationIgnored var onRetarget: (() -> Void)?
    /// Whether the flow changed since it was loaded or saved.
    public var isDirty = false
    /// The plan, or why the flow cannot run. Recomputed on every change.
    public private(set) var validation: Result<FlowPlan, FlowError>
    /// Earlier states of the flow, oldest first.
    public private(set) var undoStack: [Flow] = []
    /// States undone, most recently undone last.
    public private(set) var redoStack: [Flow] = []
    /// The selected node.
    public var selection: NodeID?

    /// The canvas view transform.
    var geometry = CanvasGeometry()
    /// The canvas view's size, once measured.
    var canvasSize: Size<Pixels>?
    @ObservationIgnored private var hasFitted = false
    @ObservationIgnored var panStart: ScreenPoint?
    @ObservationIgnored var pinchStart: (pan: ScreenPoint, zoom: Double)?

    /// Creates a draft.
    public init(flow: Flow, url: URL?, repo: URL) {
        self.flow = flow
        self.url = url
        self.repo = repo
        self.validation = Self.validate(flow)
    }

    private static func validate(_ flow: Flow) -> Result<FlowPlan, FlowError> {
        do { return .success(try flow.validate()) } catch { return .failure(error) }
    }

    /// The plan when the flow is valid.
    public var plan: FlowPlan? { try? validation.get() }

    /// Applies `change` to the flow as one undo step named `name`, marking the draft dirty.
    public func edit(_ name: String, _ change: (inout Flow) -> Void) {
        var updated = flow
        change(&updated)
        guard updated != flow else { return }
        undoStack.append(flow)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst(undoStack.count - Self.historyLimit) }
        redoStack = []
        flow = updated
        isDirty = true
    }

    /// Steps back one edit.
    public func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(flow)
        flow = previous
        isDirty = true
    }

    /// Re-applies the last undone edit.
    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(flow)
        flow = next
        isDirty = true
    }

    /// Records the canvas size and fits the flow the first time it is known.
    func canvasSizeChanged(_ size: Size<Pixels>) {
        guard size.width.value > 0, size.height.value > 0 else { return }
        canvasSize = size
        if !hasFitted {
            hasFitted = true
            geometry = geometry.fit(flow, in: size)
        }
    }

    /// Fits the flow into the canvas.
    func fit() {
        if let canvasSize { geometry = geometry.fit(flow, in: canvasSize) }
    }

    /// Marks the flow as saved to `url`.
    func didSave(to url: URL) {
        self.url = url
        isDirty = false
    }
}
