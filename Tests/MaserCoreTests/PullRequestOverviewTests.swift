// Tests for decoding and deriving the PR overview: metadata, checks, the timeline and reviewer verdicts.
//
// Everything decodes from one realistic `gh api graphql` response. The suite also holds small tests for quoting
// Markdown in a reply and for `FileTree.filePaths(in:)`.

import Foundation
import Testing

@testable import MaserCore

/// Tests for `PullRequestOverview` decoding and the values derived from it.
@Suite struct PullRequestOverviewTests {
    /// A trimmed `gh api graphql` response for `PullRequestOverview.query`.
    static let response = """
        {"data":{"repository":{"pullRequest":{
          "number":7,"title":"Add thing","url":"https://github.com/o/r/pull/7","state":"OPEN","isDraft":false,
          "createdAt":"2026-10-20T10:00:00Z","author":{"login":"alice"},
          "baseRefName":"main","headRefName":"alice/thing","additions":10,"deletions":2,"changedFiles":3,
          "body":"Hello","bodyHTML":"<p>Hello</p>","mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","reviewDecision":"CHANGES_REQUESTED",
          "labels":{"nodes":[{"name":"bug","color":"d73a4a"}]},
          "reviewRequests":{"nodes":[{"requestedReviewer":{"login":"erin"}},{"requestedReviewer":{"name":"core-team"}},{"requestedReviewer":null}]},
          "comments":{"nodes":[
            {"id":"IC_1","author":{"login":"bob"},"body":"LGTM?","bodyHTML":"<p>LGTM?</p>","createdAt":"2026-10-21T10:00:00Z","url":"https://github.com/o/r/pull/7#issuecomment-1"},
            {"id":"IC_2","author":null,"bodyHTML":"<p>deleted user</p>","createdAt":"2026-10-23T10:00:00Z","url":"https://github.com/o/r/pull/7#issuecomment-2"}
          ]},
          "reviews":{"nodes":[
            {"id":"R1","author":{"login":"carol"},"state":"COMMENTED","bodyHTML":"","submittedAt":"2026-10-21T12:00:00Z","url":"https://github.com/o/r/pull/7#r1"},
            {"id":"R2","author":{"login":"carol"},"state":"CHANGES_REQUESTED","bodyHTML":"<p>Fix it</p>","submittedAt":"2026-10-22T12:00:00Z","url":"https://github.com/o/r/pull/7#r2"},
            {"id":"R3","author":{"login":"carol"},"state":"COMMENTED","bodyHTML":"<p>one more</p>","submittedAt":"2026-10-24T12:00:00Z","url":"https://github.com/o/r/pull/7#r3"},
            {"id":"R4","author":{"login":"dave"},"state":"APPROVED","bodyHTML":"","submittedAt":"2026-10-22T13:00:00Z","url":"https://github.com/o/r/pull/7#r4"},
            {"id":"R5","author":{"login":"me"},"state":"PENDING","bodyHTML":"","submittedAt":null,"url":"https://github.com/o/r/pull/7#r5"}
          ]},
          "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[
            {"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://ci/1","checkSuite":{"workflowRun":{"workflow":{"name":"Lint"}}}},
            {"__typename":"CheckRun","name":"test","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://ci/2","checkSuite":{"workflowRun":null}},
            {"__typename":"CheckRun","name":"build","status":"IN_PROGRESS","conclusion":null,"detailsUrl":"","checkSuite":null},
            {"__typename":"CheckRun","name":"label","status":"COMPLETED","conclusion":"SKIPPED","detailsUrl":null,"checkSuite":null},
            {"__typename":"StatusContext","context":"ci/legacy","state":"ERROR","targetUrl":"https://ci/3","description":"Timed out"}
          ]}}}}]}
        }}}}
        """

    /// Decodes `response`.
    func decoded() throws -> PullRequestOverview {
        try PullRequestOverview.decode(from: Data(Self.response.utf8))
    }

    /// Decodes PR metadata, including team reviewers by name, skipping null reviewers, and a deleted author as `ghost`.
    @Test func decodesMetadata() throws {
        let pr = try decoded()
        #expect(pr.number == 7)
        #expect(pr.state == .open)
        #expect(pr.author == "alice")
        #expect(pr.headRef == "alice/thing")
        #expect(pr.mergeable == .mergeable)
        #expect(pr.mergeState == .blocked)
        #expect(pr.reviewDecision == .changesRequested)
        #expect(pr.labels == [.init(name: "bug", color: "d73a4a")])
        #expect(pr.requestedReviewers == ["erin", "core-team"])
        #expect(pr.comments[1].author == "ghost")
        #expect(pr.body == "Hello")
        #expect(pr.comments[0].body == "LGTM?")
        #expect(pr.comments[1].body == "")  // body missing
    }

    /// Quotes text line by line, normalizing CRLF, and puts a blank line between the quote and any existing text.
    @Test func quotingMarkdown() {
        #expect(Markdown.appendingQuote(of: "one\r\n\ntwo\n", to: "") == "> one\n>\n> two\n\n")
        #expect(Markdown.appendingQuote(of: "b", to: "my reply  \n") == "my reply\n\n> b\n\n")
    }

    /// Maps check runs and legacy status contexts to one check type, sorted failures first, with the workflow name or
    /// status description as the detail.
    @Test func checksMappedAndSortedByUrgency() throws {
        let pr = try decoded()
        #expect(pr.checksRollup == .failure)
        #expect(pr.checks.map(\.name) == ["ci/legacy", "test", "build", "lint", "label"])
        #expect(pr.checks.map(\.state) == [.failure, .failure, .pending, .success, .skipped])
        #expect(pr.checks.first?.detail == "Timed out")
        #expect(pr.checks.first { $0.name == "lint" }?.detail == "Lint")
        #expect(pr.checks.first { $0.name == "build" }?.url == nil)  // empty detailsUrl
    }

    /// Drops pending reviews, and leaves comment-only reviews with no body out of the date-ordered timeline.
    @Test func timelineSkipsPendingAndBodylessCommentReviews() throws {
        let pr = try decoded()
        #expect(pr.reviews.map(\.id) == ["R1", "R2", "R3", "R4"])  // pending R5 dropped
        #expect(pr.timeline.map(\.id) == ["IC_1", "R2", "R4", "IC_2", "R3"])
        #expect(pr.timeline[2].kind == .review(.approved))
    }

    /// Gives each reviewer their latest approval or change request, ignoring plain comments that come after it.
    @Test func reviewerStatusKeepsLatestVerdict() throws {
        let statuses = try decoded().reviewerStatuses
        // carol's later plain comment doesn't override her change request.
        #expect(
            statuses == [
                ReviewerStatus(author: "carol", state: .changesRequested),
                ReviewerStatus(author: "dave", state: .approved),
            ])
    }

    @Test func unknownEnumValuesDontBreakDecoding() throws {
        let json = Self.response
            .replacingOccurrences(of: #""mergeStateStatus":"BLOCKED""#, with: #""mergeStateStatus":"SOMETHING_NEW""#)
            .replacingOccurrences(of: #""reviewDecision":"CHANGES_REQUESTED""#, with: #""reviewDecision":null"#)
        let pr = try PullRequestOverview.decode(from: Data(json.utf8))
        #expect(pr.mergeState == .unknown)
        #expect(pr.reviewDecision == nil)
    }

    /// Leaves lists that fit in one page complete, and marks the ones whose `totalCount` says there are more.
    @Test func marksTruncatedLists() throws {
        #expect(try decoded().incompleteLists.isEmpty)
        let json = Self.response
            .replacingOccurrences(of: #""comments":{"nodes""#, with: #""comments":{"totalCount":150,"nodes""#)
            .replacingOccurrences(of: #""contexts":{"nodes""#, with: #""contexts":{"totalCount":5,"nodes""#)
        let pr = try PullRequestOverview.decode(from: Data(json.utf8))
        #expect(pr.incompleteLists == [.comments])
    }

    /// Replaces a truncated list with every item from its paged query, and marks it complete.
    @Test func replacesListsWithAllPages() throws {
        var pr = try decoded()
        pr.incompleteLists = [.comments, .checks]
        let comments = """
            {"id":"IC_0","author":{"login":"zed"},"body":"first","bodyHTML":"<p>first</p>","createdAt":"2026-10-20T11:00:00Z","url":"https://github.com/o/r/pull/7#issuecomment-0"}
            {"id":"IC_1","author":{"login":"bob"},"body":"LGTM?","bodyHTML":"<p>LGTM?</p>","createdAt":"2026-10-21T10:00:00Z","url":"https://github.com/o/r/pull/7#issuecomment-1"}

            """
        try pr.replace(.comments, withLines: Data(comments.utf8))
        #expect(pr.comments.map(\.id) == ["IC_0", "IC_1"])
        #expect(pr.incompleteLists == [.checks])

        let checks = """
            {"__typename":"CheckRun","name":"zz","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":null,"checkSuite":null}
            {"__typename":"StatusContext","context":"aa","state":"FAILURE","targetUrl":null,"description":null}
            """
        try pr.replace(.checks, withLines: Data(checks.utf8))
        #expect(pr.checks.map(\.name) == ["aa", "zz"])
        #expect(pr.incompleteLists.isEmpty)
    }

    /// Each paged query takes `$endCursor` and selects `pageInfo`, as `gh api graphql --paginate` needs.
    @Test func pagedQueriesPaginate() {
        for list in PullRequestOverview.PagedList.allCases {
            let (query, jq) = PullRequestOverview.pagedQuery(for: list)
            #expect(query.contains("$endCursor: String") && query.contains("after: $endCursor"))
            #expect(query.contains("pageInfo { hasNextPage endCursor }"))
            #expect(jq.hasSuffix(".nodes[]"))
        }
    }

    @Test func missingPullRequestThrows() {
        #expect(throws: (any Error).self) {
            try PullRequestOverview.decode(from: Data(#"{"data":{"repository":{"pullRequest":null}}}"#.utf8))
        }
    }

    /// Lists a tree's file paths in sidebar order: directories' contents before top-level files.
    @Test func filePathsInDisplayOrder() {
        let tree = FileTree.build(paths: ["z.txt", "src/b.swift", "src/a.swift"])
        #expect(FileTree.filePaths(in: tree) == ["src/a.swift", "src/b.swift", "z.txt"])
    }
}
