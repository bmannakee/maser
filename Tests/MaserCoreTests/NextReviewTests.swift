// Tests for choosing the PR the queue focuses next, and when focus may move to it.

import Foundation
import Testing

@testable import MaserCore

/// Tests for `NextReview`.
@Suite struct NextReviewTests {
    /// Builds a PR, updated `age` seconds ago.
    private static func pr(_ number: Int, age: Double = 0) -> PullRequest { PullRequestSearchTests.pr(number, age: age) }

    /// The first PR shown under Review requested, wherever that section is, after de-duplication and the filter.
    @Test("REQ-QUE-008: Focuses the first PR in Review requested") func target() {
        let sections = [
            QueueSection(search: .yours, prs: [Self.pr(9)]),
            QueueSection(search: .reviewRequested, prs: [Self.pr(1, age: 100), Self.pr(2, age: 10)]),
        ]
        let next = NextReview()
        #expect(next.target(in: QueueSection.displayed(sections)) == Self.pr(2).id)
        #expect(next.target(in: QueueSection.displayed(sections, filter: "#1")) == Self.pr(1).id)
        #expect(next.target(in: QueueSection.displayed(sections, filter: "#9")) == nil)
        #expect(next.target(in: QueueSection.displayed([QueueSection(search: .yours, prs: [Self.pr(9)])])) == nil)
        #expect(next.target(in: QueueSection.displayed([QueueSection(search: .reviewRequested, prs: nil)])) == nil)
        // A custom search with the same query isn't Review requested.
        let lookalike = PullRequestSearch(name: "Mine to review", query: "review-requested:@me")
        #expect(next.target(in: [QueueSection(search: lookalike, prs: [Self.pr(3)])]) == nil)
    }

    /// A PR just reviewed is skipped while the search still lists it, and focusable again once it has left.
    @Test("REQ-QUE-008: Skips a PR just reviewed until it leaves Review requested") func skipsReviewed() {
        var next = NextReview()
        let listed = [QueueSection(search: .reviewRequested, prs: [Self.pr(1), Self.pr(2, age: 10)])]
        next.submitted(Self.pr(1).id)
        #expect(next.target(in: listed) == Self.pr(2).id)

        // Still listed: still skipped.
        next.loaded(listed)
        #expect(next.target(in: listed) == Self.pr(2).id)
        // A failed search keeps its old results, which doesn't mean the PR left.
        next.loaded([QueueSection(search: .reviewRequested, prs: [Self.pr(2)], error: "HTTP 502")])
        #expect(next.reviewed == [Self.pr(1).id])

        // Gone from Review requested, then asked for again: focused again.
        next.loaded([QueueSection(search: .reviewRequested, prs: [Self.pr(2)])])
        #expect(next.reviewed.isEmpty)
        #expect(next.target(in: listed) == Self.pr(1).id)

        // The only PR reviewed: nothing to focus.
        next.submitted(Self.pr(1).id)
        #expect(next.target(in: [QueueSection(search: .reviewRequested, prs: [Self.pr(1)])]) == nil)
        // No Review requested section any more: forgotten.
        next.loaded([QueueSection(search: .yours, prs: [])])
        #expect(next.reviewed.isEmpty)
    }

    /// A load moves focus only while the queue has the keys; a submit always does; unsent text stops both.
    @Test("REQ-QUE-008: Moves focus only when it can't disturb a review") func mayMove() {
        #expect(NextReview.mayMove(after: .load, queueHasKeys: true, openReviewHasUnsentText: false))
        #expect(!NextReview.mayMove(after: .load, queueHasKeys: false, openReviewHasUnsentText: false))
        #expect(!NextReview.mayMove(after: .load, queueHasKeys: true, openReviewHasUnsentText: true))
        #expect(NextReview.mayMove(after: .submitted, queueHasKeys: false, openReviewHasUnsentText: false))
        #expect(!NextReview.mayMove(after: .submitted, queueHasKeys: false, openReviewHasUnsentText: true))
    }
}
