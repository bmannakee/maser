import Foundation
import Testing

@testable import MaserCore

@Suite struct ReviewThreadTests {
    // Shape produced by `gh api graphql --paginate --jq ReviewThread.jqFilter`: one thread per line.
    static let lines = """
        {"id":"T1","path":"a.txt","line":15,"startLine":null,"originalLine":15,"diffSide":"RIGHT","isOutdated":false,"isResolved":true,"comments":{"nodes":[{"id":"C1","author":{"login":"alice"},"body":"Root on line 15","createdAt":"2026-10-28T19:34:26Z","url":"https://github.com/o/r/pull/1#discussion_r1","state":"SUBMITTED"},{"id":"C2","author":{"login":"me"},"body":"Draft reply","createdAt":"2026-10-28T22:45:08Z","url":"https://github.com/o/r/pull/1#discussion_r2","state":"PENDING"}]}}
        {"id":"T2","path":"a.txt","line":null,"startLine":null,"originalLine":4,"diffSide":"LEFT","isOutdated":true,"isResolved":false,"comments":{"nodes":[{"id":"C3","author":null,"body":"Outdated","createdAt":"2026-10-27T10:00:00Z","url":"https://github.com/o/r/pull/1#discussion_r3","state":"SUBMITTED"}]}}
        {"id":"T3","path":"a.txt","line":5,"startLine":3,"originalLine":5,"diffSide":"LEFT","isOutdated":false,"isResolved":false,"comments":{"nodes":[{"id":"C4","author":{"login":"me"},"body":"Draft range","createdAt":"2026-10-29T10:00:00Z","url":null,"state":"PENDING"}]}}
        {"id":"T4","path":"a.txt","line":9,"startLine":null,"originalLine":9,"diffSide":"RIGHT","isOutdated":false,"isResolved":false,"comments":{"nodes":[]}}

        """

    @Test func decodesThreads() throws {
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

    @Test func emptyOutput() throws {
        #expect(try ReviewThread.decodeLines(from: Data()).isEmpty)
    }

    @Test func decodesReviewContext() throws {
        let json = #"{"data":{"repository":{"pullRequest":{"id":"PR_1","reviews":{"nodes":[{"id":"PRR_9"}]}}}}}"#
        #expect(try ReviewContext.decode(from: Data(json.utf8)) == ReviewContext(pullRequestID: "PR_1", pendingReviewID: "PRR_9"))
        let none = #"{"data":{"repository":{"pullRequest":{"id":"PR_1","reviews":{"nodes":[]}}}}}"#
        #expect(try ReviewContext.decode(from: Data(none.utf8)).pendingReviewID == nil)
    }
}

@Suite struct CommentTargetTests {
    // Two hunks: ids 0 (header) 1-4, then 5 (header) 6-8 and a no-newline marker (9).
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

    @Test func commentableLines() {
        #expect(Self.file.commentableLines.map(\.id) == [1, 2, 3, 4, 6, 7, 8])
    }

    @Test func singleLine() throws {
        let deletion = try #require(Self.file.commentTarget(anchor: nil, cursor: 2))
        #expect(deletion.side == .left && deletion.line == 2 && deletion.startLine == nil)
        #expect(deletion.description == "old line 2")

        let addition = try #require(Self.file.commentTarget(anchor: 3, cursor: 3))
        #expect(addition.side == .right && addition.line == 2)
        #expect(addition.description == "line 2")
    }

    @Test func rangeAcrossSides() throws {
        let target = try #require(Self.file.commentTarget(anchor: 4, cursor: 2))
        #expect(target.startSide == .left && target.startLine == 2)
        #expect(target.side == .right && target.line == 3)
        #expect(target.lineIDs == 2...4)
        #expect(target.description == "lines old 2–3")
    }

    @Test func rangeIsClippedToTheCursorsHunk() {
        #expect(Self.file.selectionRange(anchor: 1, cursor: 7) == 6...7)
        #expect(Self.file.selectionRange(anchor: 8, cursor: 3) == 3...4)
        #expect(Self.file.selectionRange(anchor: nil, cursor: 3) == 3...3)
    }
}

/// Hits GitHub through `gh`. Run with `MASER_LIVE_TESTS=1 swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MASER_LIVE_TESTS"] != nil))
struct LiveGitHubTests {
    @Test func loadsRealPullRequest() async throws {
        let json = """
            [{"author":{"login":"BagToad"},"isDraft":false,"number":14858,
              "repository":{"name":"cli","nameWithOwner":"cli/cli"},"title":"x",
              "updatedAt":"2026-10-28T00:00:00Z","url":"https://github.com/cli/cli/pull/14858"}]
            """
        let pr = try #require(try PullRequest.decodeList(from: Data(json.utf8)).first)
        let cli = try GitHubCLI()

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
}

/// Writes to GitHub: creates a pending review (visible only to you) on the closed test PR
/// bmannakee/maser#1, then deletes it. Run with `MASER_LIVE_WRITE_TESTS=1 swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MASER_LIVE_WRITE_TESTS"] != nil))
struct LiveReviewWriteTests {
    @Test func pendingReviewRoundTrip() async throws {
        let cli = try GitHubCLI()
        let pr = try await cli.pullRequest(url: URL(string: "https://github.com/bmannakee/maser/pull/1")!)
        let file = try #require(try await cli.fileDiffs(for: pr).first { $0.path == "COMMENT-TEST.md" })
        let lines = file.commentableLines
        let range = try #require(file.commentTarget(anchor: lines[2].id, cursor: lines[4].id))
        let single = try #require(file.commentTarget(anchor: nil, cursor: lines[0].id))

        var context = try await cli.reviewContext(for: pr)
        if let stale = context.pendingReviewID {
            try await cli.discardReview(on: pr, reviewID: stale)
        }
        let reviewID = try await cli.startReview(on: pr, pullRequestID: context.pullRequestID)
        context.pendingReviewID = reviewID
        let started = try await cli.reviewContext(for: pr)
        #expect(started == context)

        try await cli.addReviewThread(on: pr, reviewID: reviewID, target: range, body: "range")
        try await cli.addReviewThread(on: pr, reviewID: reviewID, target: single, body: "single")
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
}
