import Foundation
import Testing

@testable import MaserCore

@Suite struct PullRequestOverviewTests {
    /// Trimmed `gh api graphql` response for PullRequestOverview.query.
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

    func decoded() throws -> PullRequestOverview {
        try PullRequestOverview.decode(from: Data(Self.response.utf8))
    }

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

    @Test func quotingMarkdown() {
        #expect(Markdown.appendingQuote(of: "one\r\n\ntwo\n", to: "") == "> one\n>\n> two\n\n")
        #expect(Markdown.appendingQuote(of: "b", to: "my reply  \n") == "my reply\n\n> b\n\n")
    }

    @Test func checksMappedAndSortedByUrgency() throws {
        let pr = try decoded()
        #expect(pr.checksRollup == .failure)
        #expect(pr.checks.map(\.name) == ["ci/legacy", "test", "build", "lint", "label"])
        #expect(pr.checks.map(\.state) == [.failure, .failure, .pending, .success, .skipped])
        #expect(pr.checks.first?.detail == "Timed out")
        #expect(pr.checks.first { $0.name == "lint" }?.detail == "Lint")
        #expect(pr.checks.first { $0.name == "build" }?.url == nil)  // empty detailsUrl
    }

    @Test func timelineSkipsPendingAndBodylessCommentReviews() throws {
        let pr = try decoded()
        #expect(pr.reviews.map(\.id) == ["R1", "R2", "R3", "R4"])  // pending R5 dropped
        #expect(pr.timeline.map(\.id) == ["IC_1", "R2", "R4", "IC_2", "R3"])
        #expect(pr.timeline[2].kind == .review(.approved))
    }

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

    @Test func missingPullRequestThrows() {
        #expect(throws: (any Error).self) {
            try PullRequestOverview.decode(from: Data(#"{"data":{"repository":{"pullRequest":null}}}"#.utf8))
        }
    }

    @Test func filePathsInDisplayOrder() {
        let tree = FileTree.build(paths: ["z.txt", "src/b.swift", "src/a.swift"])
        #expect(FileTree.filePaths(in: tree) == ["src/a.swift", "src/b.swift", "z.txt"])
    }
}
