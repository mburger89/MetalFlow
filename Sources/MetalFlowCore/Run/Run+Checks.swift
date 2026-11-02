import Foundation

/// How far a check (a gate or a review) got on a candidate.
public enum CheckStatus: Equatable, Sendable {
    /// The flow has no such check, or it was skipped because an earlier one failed.
    case none
    /// The check ran and passed.
    case passed
    /// The check ran and failed.
    case failed
    /// The flow has the check but it has no result: it errored, was cut short or is still to run.
    case notFinished
}

extension Run {
    /// Whether the flow has a gate.
    public var hasGate: Bool { flow.nodes.contains { if case .gate = $0.kind { true } else { false } } }

    /// Whether the flow has a review.
    public var hasReview: Bool { flow.nodes.contains { if case .review = $0.kind { true } else { false } } }

    /// How the tests went on `lane`: `.none` when the flow has no gate.
    public func testsStatus(of lane: Lane) -> CheckStatus {
        switch lane.gatePassed {
        case true?: .passed
        case false?: .failed
        case nil: hasGate ? .notFinished : .none
        }
    }

    /// How the review went on `lane`: `.none` when the flow has no review, or when failing tests skipped it.
    public func reviewStatus(of lane: Lane) -> CheckStatus {
        switch lane.reviewPassed {
        case true?: .passed
        case false?: .failed
        case nil: hasReview && lane.gatePassed != false ? .notFinished : .none
        }
    }

    /// The output of the flow's Review in `lane`, when it has one.
    public func reviewOutput(of lane: LaneID) -> String? {
        guard let review = flow.nodes.first(where: { if case .review = $0.kind { true } else { false } }) else { return nil }
        return nodes[NodeKey(node: review.id, lane: lane)]?.output
    }

    /// What the review found in `lane` (the last 40 lines of its output) when it asked for changes, else nil.
    public func reviewFindings(of lane: Lane) -> String? {
        guard lane.reviewPassed == false, let output = reviewOutput(of: lane.id) else { return nil }
        var lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        let text = lines.suffix(40).joined(separator: "\n")
        return text.isEmpty ? nil : text
    }
}
