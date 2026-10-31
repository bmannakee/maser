import Foundation
@testable import MaserCore
import Testing

@Suite struct ReviewCommentTests {
    // Shape produced by `gh api ... --jq ReviewComment.jqFilter`: one object per line.
    static let lines = """
    {"body":"Root on line 15","created_at":"2026-10-28T19:34:26Z","html_url":"https://github.com/o/r/pull/1#discussion_r1","id":1,"in_reply_to_id":null,"line":15,"original_line":15,"path":"a.txt","side":"RIGHT","user":"alice"}
    {"body":"Reply","created_at":"2026-10-28T22:45:08Z","html_url":"https://github.com/o/r/pull/1#discussion_r2","id":2,"in_reply_to_id":1,"line":15,"original_line":15,"path":"a.txt","side":"RIGHT","user":"bob"}
    {"body":"Outdated","created_at":"2026-10-27T10:00:00Z","html_url":"https://github.com/o/r/pull/1#discussion_r3","id":3,"in_reply_to_id":null,"line":null,"original_line":4,"path":"a.txt","side":"LEFT","user":"carol"}
    {"body":"Earlier line","created_at":"2026-10-29T10:00:00Z","html_url":"https://github.com/o/r/pull/1#discussion_r4","id":4,"in_reply_to_id":null,"line":2,"original_line":2,"path":"a.txt","side":"LEFT","user":"dave"}

    """

    @Test func decodesAndGroupsThreads() throws {
        let comments = try ReviewComment.decodeLines(from: Data(Self.lines.utf8))
        #expect(comments.count == 4)
        #expect(comments[1].inReplyToId == 1)
        #expect(comments[2].side == .left)

        let threads = ReviewThread.group(comments)
        #expect(threads.map(\.id) == [4, 1, 3]) // by line, outdated last
        #expect(threads[1].comments.map(\.user) == ["alice", "bob"])
        #expect(threads[2].isOutdated)
        #expect(threads[0].side == .left)
    }

    @Test func emptyOutput() throws {
        #expect(try ReviewComment.decodeLines(from: Data()).isEmpty)
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

        let threads = ReviewThread.group(try await cli.reviewComments(for: pr))
        #expect(!threads.isEmpty)
        // Every current thread should anchor to a line in its file's diff.
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        for thread in threads where !thread.isOutdated {
            let file = try #require(byPath[thread.path])
            #expect(file.lineID(side: thread.side, line: thread.line!) != nil, "\(thread.path):\(thread.line!)")
        }
    }
}
