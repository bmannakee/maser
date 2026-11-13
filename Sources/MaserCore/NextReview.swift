// Which PR the queue focuses next: the first one waiting for the viewer's review.
//
// The main window selects the first PR in Review requested at launch, after each queue load and after the viewer submits
// a review. This file holds that choice and when it may be made, so it can be tested without the UI. A PR the viewer
// has just reviewed is skipped until it leaves Review requested, and the selection never moves while the viewer is
// working in a review, or away from a review with unsent text (HAZ-04).

import Foundation

/// Picks the PR the queue should focus next, and says when focus may move to it.
public struct NextReview: Sendable, Equatable {
    /// What prompts the queue to focus the next review.
    public enum Trigger: Sendable {
        /// The queue finished loading: at launch, on a refresh, or after the searches changed.
        case load
        /// The viewer submitted a review in the window.
        case submitted
    }

    /// PRs the viewer has submitted a review on that are still in Review requested, so they aren't focused again.
    ///
    /// GitHub's search can list a PR for a while after its review is submitted.
    public private(set) var reviewed: Set<PullRequest.ID> = []

    /// Creates a picker that has seen no submitted reviews.
    public init() {}

    /// Notes that the viewer submitted a review on a PR, so it isn't focused until it leaves Review requested.
    ///
    /// - Parameter id: The reviewed PR.
    public mutating func submitted(_ id: PullRequest.ID) {
        reviewed.insert(id)
    }

    /// Forgets reviewed PRs that a load found no longer waiting for review.
    ///
    /// A failed Review requested search keeps its last results (REQ-QUE-004), so it doesn't count as the PR leaving.
    /// A queue without the section forgets them all.
    ///
    /// - Parameter sections: The queue's sections as loaded, before de-duplication and filtering.
    public mutating func loaded(_ sections: [QueueSection]) {
        guard let section = sections.first(where: { $0.search == .reviewRequested }) else {
            reviewed = []
            return
        }
        guard section.error == nil, let prs = section.prs else { return }
        reviewed.formIntersection(prs.map(\.id))
    }

    /// The PR to focus: the first shown in Review requested that the viewer hasn't just reviewed.
    ///
    /// - Parameter displayed: The sections as shown, after de-duplication and the filter.
    /// - Returns: The PR, or `nil` when the queue has no Review requested section or nothing left in it.
    public func target(in displayed: [QueueSection]) -> PullRequest.ID? {
        displayed.first { $0.search == .reviewRequested }?.prs?.first { !reviewed.contains($0.id) }?.id
    }

    /// Whether the queue's selection may move to the next review.
    ///
    /// After a load it moves only while the queue has the keys, so it never pulls the viewer out of a review they're
    /// working in. After a submit the review is finished, so it moves either way. Neither moves away from a review with
    /// unsent text, which would hide that text.
    ///
    /// - Parameters:
    ///   - trigger: What prompted the move.
    ///   - queueHasKeys: Whether the queue has the keys, which it does when no review is open.
    ///   - openReviewHasUnsentText: Whether the review showing has text that hasn't been posted.
    /// - Returns: True if the selection may move.
    public static func mayMove(after trigger: Trigger, queueHasKeys: Bool, openReviewHasUnsentText: Bool) -> Bool {
        guard !openReviewHasUnsentText else { return false }
        switch trigger {
        case .load: return queueHasKeys
        case .submitted: return true
        }
    }
}
