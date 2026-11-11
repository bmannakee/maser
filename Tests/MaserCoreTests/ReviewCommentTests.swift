// Tests for inline review threads, comment targets and the review-writing calls.
//
// The offline suites decode review threads and `ReviewContext` from fixtures and map diff selections to
// `CommentTarget`s. Two opt-in suites run against GitHub through `gh`: one reads a real PR, and one creates and deletes
// a pending review on a test PR.

import Foundation
import Testing

@testable import MaserCore

/// Tests for decoding review threads and the review context.
@Suite struct ReviewThreadTests {
    /// Output in the shape `gh api graphql --paginate --jq ReviewThread.jqFilter` produces: one thread per line.
    static let lines = """
        {"id":"T1","path":"a.txt","line":15,"startLine":null,"originalLine":15,"diffSide":"RIGHT","isOutdated":false,"isResolved":true,"comments":{"nodes":[{"id":"C1","author":{"login":"alice"},"body":"Root on line 15","createdAt":"2026-10-28T19:34:26Z","url":"https://github.com/o/r/pull/1#discussion_r1","state":"SUBMITTED"},{"id":"C2","author":{"login":"me"},"body":"Draft reply","createdAt":"2026-10-28T22:45:08Z","url":"https://github.com/o/r/pull/1#discussion_r2","state":"PENDING"}]}}
        {"id":"T2","path":"a.txt","line":null,"startLine":null,"originalLine":4,"diffSide":"LEFT","isOutdated":true,"isResolved":false,"comments":{"nodes":[{"id":"C3","author":null,"body":"Outdated","createdAt":"2026-10-27T10:00:00Z","url":"https://github.com/o/r/pull/1#discussion_r3","state":"SUBMITTED"}]}}
        {"id":"T3","path":"a.txt","line":5,"startLine":3,"originalLine":5,"diffSide":"LEFT","isOutdated":false,"isResolved":false,"comments":{"nodes":[{"id":"C4","author":{"login":"me"},"body":"Draft range","createdAt":"2026-10-29T10:00:00Z","url":null,"state":"PENDING"}]}}
        {"id":"T4","path":"a.txt","line":9,"startLine":null,"originalLine":9,"diffSide":"RIGHT","isOutdated":false,"isResolved":false,"comments":{"nodes":[]}}

        """

    /// Decodes threads sorted by line with outdated ones last, drops empty threads, and tells draft threads from draft
    /// replies.
    @Test("REQ-DIF-008: Decodes threads") func decodesThreads() throws {
        let threads = try ReviewThread.decodeLines(from: Data(Self.lines.utf8))
        #expect(threads.map(\.id) == ["T3", "T1", "T2"])  // by line, outdated last, empty dropped
        #expect(threads[0].side == .left)
        #expect(threads[0].startLine == 3)
        #expect(threads[0].isPending)
        #expect(threads[0].root.url == nil)
        #expect(threads[1].comments.map(\.author) == ["alice", "me"])
        #expect(!threads[1].isPending && threads[1].hasPendingComments)
        #expect(threads[1].removingPendingComments()?.comments.map(\.author) == ["alice"])
        #expect(threads[0].removingPendingComments() == nil)
        #expect(threads[1].isResolved)
        #expect(threads[2].isOutdated)
        #expect(threads[2].root.author == "ghost")
    }

    @Test("REQ-GH-004: Empty output") func emptyOutput() throws {
        #expect(try ReviewThread.decodeLines(from: Data()).isEmpty)
    }

    /// Decodes the PR's node ID, head commit and the viewer's login, with and without a pending review.
    @Test("REQ-CMT-001, REQ-CMT-009: Decodes review context") func decodesReviewContext() throws {
        let json = #"""
            {"data":{"viewer":{"login":"octocat"},
             "repository":{"pullRequest":{"id":"PR_1","headRefOid":"abc123","reviews":{"nodes":[{"id":"PRR_9"}]}}}}}
            """#
        #expect(
            try ReviewContext.decode(from: Data(json.utf8))
                == ReviewContext(
                    pullRequestID: "PR_1", pendingReviewID: "PRR_9", headCommitID: "abc123", viewerLogin: "octocat"))
        let none = #"{"data":{"repository":{"pullRequest":{"id":"PR_1","headRefOid":"abc123","reviews":{"nodes":[]}}}}}"#
        #expect(try ReviewContext.decode(from: Data(none.utf8)).pendingReviewID == nil)
    }

    /// Marks a thread whose first page of comments is short of its `totalCount`, then replaces its comments with the
    /// full list from `commentsQuery`.
    @Test("REQ-GH-003: Long threads get their remaining comments") func longThreadsGetTheirRemainingComments() throws {
        let line = """
            {"id":"T1","path":"a.txt","line":3,"startLine":null,"originalLine":3,"diffSide":"RIGHT","isOutdated":false,"isResolved":false,"comments":{"totalCount":3,"nodes":[{"id":"C1","author":{"login":"alice"},"body":"one","createdAt":"2026-10-28T19:34:26Z","url":null,"state":"SUBMITTED"}]}}
            """
        let thread = try #require(try ReviewThread.decodeLines(from: Data(line.utf8)).first)
        #expect(thread.hasMoreComments)
        let notLong = try #require(try ReviewThread.decodeLines(from: Data(Self.lines.utf8)).first)
        #expect(!notLong.hasMoreComments)

        let all = """
            {"id":"C1","author":{"login":"alice"},"body":"one","createdAt":"2026-10-28T19:34:26Z","url":null,"state":"SUBMITTED"}
            {"id":"C2","author":null,"body":"two","createdAt":"2026-10-28T19:35:26Z","url":null,"state":"SUBMITTED"}
            {"id":"C3","author":{"login":"me"},"body":"three","createdAt":"2026-10-28T19:36:26Z","url":null,"state":"PENDING"}

            """
        let full = thread.replacingComments(try ReviewThread.decodeCommentLines(from: Data(all.utf8)))
        #expect(full.comments.map(\.body) == ["one", "two", "three"])
        #expect(full.comments.map(\.author) == ["alice", "ghost", "me"])
        #expect(full.hasPendingComments)
        #expect(!full.hasMoreComments)
        #expect(thread.replacingComments([]) == thread)
    }
}

/// Pinning comments and reviews to the commit whose diff the user saw (RC-04).
@Suite struct CommitPinningTests {
    let context = ReviewContext(
        pullRequestID: "PR_1", pendingReviewID: nil, headCommitID: "4e5b8e054d5da90dc647db34891d6247c454f495")

    @Test("REQ-CMT-007: Posting is refused once the head has moved") func refusesAfterHeadMoved() throws {
        try context.requireHead("4e5b8e054d5da90dc647db34891d6247c454f495")
        let error = #expect(throws: GitHubCLIError.self) { try context.requireHead("4a3f86d") }
        guard case let .headMoved(seen, current) = error else {
            Issue.record("expected headMoved, got \(String(describing: error))")
            return
        }
        #expect(seen == "4a3f86d" && current == context.headCommitID)
        let message = GitHubCLIError.headMoved(seen: "4a3f86d1f098", current: "4e5b8e054d5d").errorDescription ?? ""
        #expect(message.contains("4a3f86d → 4e5b8e0") && message.contains("your text is kept"))
    }

    @Test("REQ-CMT-007: A new review is pinned to the commit seen") func startPinsCommit() {
        let strings = GitHubCLI.startReviewVariables(pullRequestID: "PR_1", commitID: "4a3f86d")
        #expect(strings == ["pr": "PR_1", "commit": "4a3f86d"])
        #expect(GitHubCLI.startReviewMutation.contains("commitOID: $commit"))
    }

    @Test("REQ-CMT-007: A verdict without a pending review is pinned to the commit seen") func submitPinsCommit() {
        let request = GitHubCLI.submitReviewRequest(context: context, event: .approve, body: "", commitID: "4a3f86d")
        #expect(request.strings == ["pr": "PR_1", "commit": "4a3f86d", "event": "APPROVE"])
        #expect(request.query.contains("addPullRequestReview(input: {pullRequestId: $pr, commitOID: $commit"))
    }

    @Test("REQ-CMT-007: A pending review is submitted as pinned when it started") func submitPendingReview() {
        var pending = context
        pending.pendingReviewID = "PRR_9"
        let request = GitHubCLI.submitReviewRequest(context: pending, event: .comment, body: "Looks good", commitID: "4a3f86d")
        #expect(request.strings == ["review": "PRR_9", "event": "COMMENT", "body": "Looks good"])
        #expect(request.query.contains("submitPullRequestReview"))
    }
}

/// Checking that `gh` posts as the account the user was shown (RC-12).
@Suite struct PostingAccountTests {
    let context = ReviewContext(pullRequestID: "PR_1", pendingReviewID: nil, headCommitID: "abc123", viewerLogin: "work-me")

    @Test("REQ-CMT-009: Posts only as the account shown") func postsOnlyAsAccountShown() throws {
        try context.requireViewer("work-me")
        for shown in ["home-me", nil] {
            let error = #expect(throws: GitHubCLIError.self) { try context.requireViewer(shown) }
            guard case let .accountChanged(errorShown, current) = error else {
                Issue.record("expected accountChanged, got \(String(describing: error))")
                continue
            }
            #expect(errorShown == shown && current == "work-me")
        }
        var unknown = context
        unknown.viewerLogin = nil
        #expect(throws: GitHubCLIError.self) { try unknown.requireViewer(nil) }
    }

    @Test("REQ-CMT-009: The refusal names both accounts") func refusalNamesBothAccounts() {
        let changed = GitHubCLIError.accountChanged(shown: "home-me", current: "work-me").errorDescription ?? ""
        #expect(changed.hasPrefix("gh is signed in as @work-me, not @home-me as shown, so nothing was posted."))
        let unshown = GitHubCLIError.accountChanged(shown: nil, current: "work-me").errorDescription ?? ""
        #expect(unshown.hasPrefix("gh is signed in as @work-me, so nothing was posted."))
    }
}

/// Tests for turning a diff selection into the line or range GitHub attaches a comment to.
@Suite struct CommentTargetTests {
    /// A file with two hunks: IDs 0 (header) and 1–4, then 5 (header), 6–8 and a no-newline marker (9).
    static let file = DiffParser.parse(
        """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,3 @@
         one
        -two
        +TWO
         three
        @@ -10,2 +10,2 @@
         ten
        -eleven
        +ELEVEN
        \\ No newline at end of file

        """)[0]

    /// Excludes hunk headers and no-newline markers.
    @Test("REQ-CMT-001: Commentable lines") func commentableLines() {
        #expect(Self.file.commentableLines.map(\.id) == [1, 2, 3, 4, 6, 7, 8])
    }

    /// Targets the old side for a deletion and the new side otherwise, including when the anchor equals the cursor.
    @Test("REQ-CMT-001: Single line") func singleLine() throws {
        let deletion = try #require(Self.file.commentTarget(anchor: nil, cursor: 2))
        #expect(deletion.side == .left && deletion.line == 2 && deletion.startLine == nil)
        #expect(deletion.description == "old line 2")

        let addition = try #require(Self.file.commentTarget(anchor: 3, cursor: 3))
        #expect(addition.side == .right && addition.line == 2)
        #expect(addition.description == "line 2")
    }

    /// A range selected bottom-up from a deletion to a context line starts on the old side and ends on the new.
    @Test("REQ-CMT-001: Range across sides") func rangeAcrossSides() throws {
        let target = try #require(Self.file.commentTarget(anchor: 4, cursor: 2))
        #expect(target.startSide == .left && target.startLine == 2)
        #expect(target.side == .right && target.line == 3)
        #expect(Self.file.lineIDs(for: target) == 2...4)
        #expect(target.description == "old line 2 to line 3")
        #expect(CommentTarget.describe(side: .right, line: 5, startSide: .right, startLine: 5) == "line 5")
        #expect(CommentTarget.describe(side: .left, line: 5, startSide: nil, startLine: 3) == "old lines 3–5")
    }

    @Test("REQ-CMT-001: Range is clipped to the cursor's hunk") func rangeIsClippedToTheCursorsHunk() {
        #expect(Self.file.selectionRange(anchor: 1, cursor: 7) == 6...7)
        #expect(Self.file.selectionRange(anchor: 8, cursor: 3) == 3...4)
        #expect(Self.file.selectionRange(anchor: nil, cursor: 3) == 3...3)
    }
}

/// Read-only tests against GitHub through `gh`, using a real merged PR in `cli/cli`.
///
/// Opt-in, since they need network access and a logged-in `gh`. Run with `MASER_LIVE_TESTS=1 swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MASER_LIVE_TESTS"] != nil))
struct LiveGitHubTests {
    /// The review context names the account `gh api user` reports, which is who Maser posts as.
    @Test("REQ-CMT-009: Names gh's account") func namesGHAccount() async throws {
        let cli = GitHubCLI()
        let pr = try await cli.pullRequest(url: URL(string: "https://github.com/bmannakee/maser/pull/1")!)
        let user = try await cli.run(["api", "--hostname", pr.host, "user", "--jq", ".login"])
        let login = String(decoding: user, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!login.isEmpty)
        #expect(try await cli.reviewContext(for: pr).viewerLogin == login)
    }

    /// Loads the diff, overview and threads, and checks that every current thread maps to a line in the parsed diff.
    @Test("REQ-DIF-001, REQ-DIF-008: Loads real pull request") func loadsRealPullRequest() async throws {
        let json = """
            [{"author":{"login":"BagToad"},"isDraft":false,"number":14858,
              "repository":{"name":"cli","nameWithOwner":"cli/cli"},"title":"x",
              "updatedAt":"2026-10-28T00:00:00Z","url":"https://github.com/cli/cli/pull/14858"}]
            """
        let pr = try #require(try PullRequest.decodeList(from: Data(json.utf8)).first)
        let cli = GitHubCLI()

        let files = try await cli.fileDiffs(for: pr)
        #expect(!files.isEmpty)
        #expect(files.allSatisfy { !$0.path.isEmpty })

        let overview = try await cli.overview(for: pr)
        #expect(overview.number == 14858)
        #expect(overview.state == .merged)
        #expect(!overview.bodyHTML.isEmpty)
        #expect(!overview.checks.isEmpty)
        #expect(overview.reviewerStatuses.contains { $0.state == .approved })

        let threads = try await cli.reviewThreads(for: pr)
        #expect(!threads.isEmpty)
        // Every current thread should anchor to a line in its file's diff.
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        for thread in threads where !thread.isOutdated {
            let file = try #require(byPath[thread.path])
            #expect(file.lineID(side: thread.side, line: thread.line!) != nil, "\(thread.path):\(thread.line!)")
        }
    }

    /// Fetches every page of a busy PR's lists: rust-lang/rust#162811 has more than 100 conversation comments.
    ///
    /// Also runs each paged query and the thread-comments query directly, so a typo in any of them fails here.
    @Test("REQ-GH-003: Paginates long lists") func paginatesLongLists() async throws {
        let cli = GitHubCLI()
        let pr = try await cli.pullRequest(url: URL(string: "https://github.com/rust-lang/rust/pull/162811")!)
        let overview = try await cli.overview(for: pr)
        #expect(overview.comments.count > 100)
        #expect(overview.incompleteLists.isEmpty)
        let ids = overview.comments.map(\.id)
        #expect(Set(ids).count == ids.count)

        var paged = overview
        for list in PullRequestOverview.PagedList.allCases {
            let (query, jq) = PullRequestOverview.pagedQuery(for: list)
            let lines = try await cli.graphQL(
                query, host: pr.host, paginate: true, jq: jq, strings: try cli.repoVariables(pr), ints: ["number": pr.number])
            try paged.replace(list, withLines: lines)
        }
        #expect(paged.comments == overview.comments)
        #expect(paged.reviews == overview.reviews)
        #expect(paged.checks.count == overview.checks.count)

        let thread = try #require(try await cli.reviewThreads(for: pr).first)
        let comments = try await cli.graphQL(
            ReviewThread.commentsQuery, host: pr.host, paginate: true, jq: ReviewThread.commentsJQFilter,
            strings: ["thread": thread.id])
        #expect(try ReviewThread.decodeCommentLines(from: comments) == thread.comments)
    }
}

/// Tests that write to GitHub, on the closed test PR `bmannakee/maser#1`.
///
/// They create a pending review, visible only to you, then delete it. Run with `MASER_LIVE_WRITE_TESTS=1 swift test`.
/// They run one at a time, because GitHub allows only one pending review per user per PR.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MASER_LIVE_WRITE_TESTS"] != nil))
struct LiveReviewWriteTests {
    /// Runs a pending review through its whole life, checking GitHub's state after each step.
    ///
    /// Starts a review, adds a range thread and a single-line thread, checks that a thread on a line outside the diff is
    /// an error, replies, deletes the reply and discards the review. Any existing pending review is discarded first.
    @Test("REQ-CMT-001, REQ-CMT-002, REQ-CMT-005, REQ-CMT-006: Pending review round trip") func pendingReviewRoundTrip()
        async throws
    {
        let cli = GitHubCLI()
        let pr = try await cli.pullRequest(url: URL(string: "https://github.com/bmannakee/maser/pull/1")!)
        let file = try #require(try await cli.fileDiffs(for: pr).first { $0.path == "COMMENT-TEST.md" })
        let lines = file.commentableLines
        let range = try #require(file.commentTarget(anchor: lines[2].id, cursor: lines[4].id))
        let single = try #require(file.commentTarget(anchor: nil, cursor: lines[0].id))

        var context = try await cli.reviewContext(for: pr)
        if let stale = context.pendingReviewID {
            try await cli.discardReview(on: pr, reviewID: stale)
            context.pendingReviewID = nil
        }
        let reviewID = try await cli.startReview(
            on: pr, pullRequestID: context.pullRequestID, commitID: context.headCommitID)
        context.pendingReviewID = reviewID
        let started = try await cli.reviewContext(for: pr)
        #expect(started == context)

        try await cli.addReviewThread(on: pr, reviewID: reviewID, target: range, body: "range")
        try await cli.addReviewThread(on: pr, reviewID: reviewID, target: single, body: "single")
        // README.md's diff covers lines 1–6. GitHub answers line 40 with a null thread, which must not pass silently.
        let outside = CommentTarget(path: "README.md", side: .right, line: 40, startSide: nil, startLine: nil)
        await #expect(throws: GitHubCLIError.self) {
            try await cli.addReviewThread(on: pr, reviewID: reviewID, target: outside, body: "outside")
        }
        var threads = try await cli.reviewThreads(for: pr)
        #expect(threads.count == 2)
        let allPending = threads.allSatisfy(\.isPending)
        #expect(allPending)
        let rangeThread = try #require(threads.first { $0.root.body == "range" })
        #expect(rangeThread.startLine == range.startLine && rangeThread.line == range.line)

        try await cli.reply(on: pr, toThread: rangeThread.id, body: "reply")
        threads = try await cli.reviewThreads(for: pr)
        let replied = try #require(threads.first { $0.id == rangeThread.id })
        #expect(replied.comments.map(\.body) == ["range", "reply"])

        try await cli.deleteReviewComment(on: pr, commentID: replied.comments[1].id)
        try await cli.discardReview(on: pr, reviewID: reviewID)
        // GitHub takes a few seconds to reflect the discard.
        var remaining = try await cli.reviewThreads(for: pr)
        for _ in 0..<10 where !remaining.isEmpty {
            try await Task.sleep(for: .seconds(1))
            remaining = try await cli.reviewThreads(for: pr)
        }
        let finalContext = try await cli.reviewContext(for: pr)
        #expect(remaining.isEmpty)
        #expect(finalContext.pendingReviewID == nil)
    }

    /// Pins a review to PR #1's first commit, and checks what GitHub records.
    ///
    /// The review keeps the older commit, but a thread added to it lands on the PR's head. That's why Maser checks the
    /// head before each new thread instead of relying on the review's commit.
    @Test("REQ-CMT-007: A review is pinned to the commit seen; new threads land on the head")
    func reviewIsPinnedToCommitSeen() async throws {
        let cli = GitHubCLI()
        let pr = try await cli.pullRequest(url: URL(string: "https://github.com/bmannakee/maser/pull/1")!)
        let older = "4a3f86d1f0981128efd0a35f624f863f89384f2e"
        var (_, context) = try await cli.diffAtHead(for: pr)
        #expect(context.headCommitID != older)
        if let stale = context.pendingReviewID {
            try await cli.discardReview(on: pr, reviewID: stale)
            context.pendingReviewID = nil
        }

        let reviewID = try await cli.startReview(on: pr, pullRequestID: context.pullRequestID, commitID: older)
        do {
            let target = CommentTarget(path: "COMMENT-TEST.md", side: .right, line: 1, startSide: nil, startLine: nil)
            try await cli.addReviewThread(on: pr, reviewID: reviewID, target: target, body: "pinning")
            let data = try await cli.graphQL(
                """
                query($review: ID!) {
                  node(id: $review) { ... on PullRequestReview { commit { oid } comments(first: 5) { nodes { commit { oid } } } } }
                }
                """, host: pr.host, strings: ["review": reviewID])
            /// The parts of the response the test reads.
            struct Response: Decodable {
                struct Payload: Decodable { let node: Review }
                struct Review: Decodable {
                    struct Commit: Decodable { let oid: String }
                    struct Comments: Decodable { let nodes: [Comment] }
                    struct Comment: Decodable { let commit: Commit }
                    let commit: Commit
                    let comments: Comments
                }
                let data: Payload
            }
            let review = try JSONDecoder().decode(Response.self, from: data).data.node
            #expect(review.commit.oid == older)
            #expect(review.comments.nodes.map(\.commit.oid) == [context.headCommitID])

            let current = try await cli.reviewContext(for: pr)
            #expect(throws: GitHubCLIError.self) { try current.requireHead(older) }
        } catch {
            try await cli.discardReview(on: pr, reviewID: reviewID)
            throw error
        }
        try await cli.discardReview(on: pr, reviewID: reviewID)
    }
}
