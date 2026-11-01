import MetalFlowCore
import MetalUI

/// A semantic colour for a state, resolved to the `Palette`.
enum Tone: Equatable, Sendable {
    /// Success green.
    case ok
    /// Failure red.
    case bad
    /// Needs-you amber.
    case warn
    /// Running blue.
    case accent
    /// Secondary grey: not started, or over without a verdict.
    case muted

    /// The foreground colour.
    var color: Color {
        switch self {
        case .ok: Palette.ok
        case .bad: Palette.bad
        case .warn: Palette.warn
        case .accent: Palette.accent
        case .muted: Palette.muted
        }
    }

    /// The dark fill behind text in `color`, as on the step pills.
    var tint: Color {
        switch self {
        case .ok: Color(Hsla.rgb(0x16261b))
        case .bad: Color(Hsla.rgb(0x2a1618))
        case .warn: Color(Hsla.rgb(0x2a2012))
        case .accent: Color(Hsla.rgb(0x152235))
        case .muted: Color(Hsla.rgb(0x1b1e23))
        }
    }
}

/// How a node state reads on every screen: one short label, one tone, one lane-summary symbol, and for the states
/// that carry more (a failure message, why the user is needed) a detail. Screens add context around it; they do not
/// re-word it.
struct NodeStateStyle: Equatable, Sendable {
    /// "Waiting", "Running", "Done", "Failed", "Needs you", "Interrupted" or "Cancelled".
    var label: String
    /// The colour family.
    var tone: Tone
    /// The one-character lane-summary mark: ✓ done, ✕ failed, ● running, ? needs you, · anything else.
    var symbol: String
    /// The failure message, or why the user is needed ("question", "approval", "pick a winner", "gate failed").
    var detail: String?

    /// The word run statuses use for a run that waits on the user.
    static let needsYouLabel = "Needs you"

    /// The style of `state`. A gate that has used fix attempts reads "Fix 1 of 2" as its detail, where the state
    /// has none of its own.
    init(_ state: NodeState, fix: Run.FixProgress? = nil) {
        switch state {
        case .waiting: (label, tone, symbol, detail) = ("Waiting", .muted, "·", nil)
        case .running: (label, tone, symbol, detail) = ("Running", .accent, "●", nil)
        case .succeeded: (label, tone, symbol, detail) = ("Done", .ok, "✓", nil)
        case .failed(let message): (label, tone, symbol, detail) = ("Failed", .bad, "✕", message)
        case .interrupted: (label, tone, symbol, detail) = ("Interrupted", .warn, "·", nil)
        case .cancelled: (label, tone, symbol, detail) = ("Cancelled", .muted, "·", nil)
        case .needsYou(let reason):
            label = Self.needsYouLabel
            symbol = "?"
            switch reason {
            case .question: (tone, detail) = (.warn, "question")
            case .deniedTools: (tone, detail) = (.warn, "approval")
            case .pickWinner(_, let allGatesFailed):
                (tone, detail) = allGatesFailed ? (.bad, "gate failed") : (.warn, "pick a winner")
            }
        }
        if detail == nil, let fix { detail = "Fix \(fix.used) of \(fix.of)" }
    }

    /// The tone's foreground colour.
    var color: Color { tone.color }

    /// The label, then the detail: "Done", "Failed: boom", "Needs you: question".
    var text: String { detail.map { "\(label): \($0)" } ?? label }
}

extension StepPill.State {
    /// The tone of a collapsed step.
    var tone: Tone {
        switch self {
        case .done: .ok
        case .run: .accent
        case .wait: .muted
        case .fail: .bad
        }
    }
}
