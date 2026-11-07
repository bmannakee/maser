// Tests for expanding a file's diff to the whole file.
//
// The offline suite merges parsed diffs with file contents: filling the gaps between hunks, numbering both sides,
// renumbering IDs, and refusing contents that don't match. An opt-in suite fetches a real file through `gh`.

import Foundation
import Testing

@testable import MaserCore

/// Tests for `FileDiff.fullFile(headText:)` and the helpers for moving between hunk and whole-file views.
@Suite struct FullFileTests {
    /// Line `n` of the head file is "n", for ten lines, except line 4, which the diff changed.
    static let headText = "1\n2\n3\nFOUR\n5\n6\n7\n8\n9\n10\n"

    /// A diff of `headText` with one hunk around line 4: lines 3–5 of 10.
    static let file = DiffParser.parse(
        """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -3,3 +3,3 @@
         3
        -4
        +FOUR
         5

        """)[0]

    /// Fills the lines before and after the hunk, numbered on both sides, as uncommentable expansion hunks.
    @Test("REQ-DIF-002, REQ-DIF-003: Fills gaps around hunks") func fillsGapsAroundHunks() throws {
        let full = try #require(Self.file.fullFile(headText: Self.headText))
        #expect(full.isFullFile)
        #expect(full.hunks.map(\.isExpansion) == [true, false, true])
        let lines = full.hunks.flatMap(\.lines)
        #expect(lines.map(\.text) == ["1", "2", "3", "4", "FOUR", "5", "6", "7", "8", "9", "10"])
        #expect(lines.map(\.newLine) == [1, 2, 3, nil, 4, 5, 6, 7, 8, 9, 10])
        #expect(lines.map(\.oldLine) == [1, 2, 3, 4, nil, 5, 6, 7, 8, 9, 10])

        // Only the diff's own lines take comments, but the cursor can stop anywhere.
        #expect(full.commentableLines.map(\.text) == ["3", "4", "FOUR", "5"])
        #expect(full.cursorLines.count == 11)
        #expect(lines[0].commentSide == nil && lines[0].commentLine == nil)

        // IDs are renumbered to increase in display order, hunks included.
        let ids = full.hunks.flatMap { [$0.id] + $0.lines.map(\.id) }
        #expect(ids == Array(0..<ids.count))
    }

    /// Keeps the two sides' numbering apart when a hunk changes the line count, and handles a hunk that only deletes.
    @Test("REQ-DIF-002: Numbers sides across length changes") func numbersSidesAcrossLengthChanges() throws {
        let file = DiffParser.parse(
            """
            diff --git a/f.txt b/f.txt
            --- a/f.txt
            +++ b/f.txt
            @@ -1,0 +2,2 @@
            +new a
            +new b
            @@ -5,2 +6,0 @@
            -gone 5
            -gone 6

            """)[0]
        // Old file: x1 … x8. New file: x1, new a, new b, x2, x3, x4, x7, x8.
        let head = "x1\nnew a\nnew b\nx2\nx3\nx4\nx7\nx8"
        let full = try #require(file.fullFile(headText: head))
        let lines = full.hunks.flatMap(\.lines)
        #expect(lines.map(\.text) == ["x1", "new a", "new b", "x2", "x3", "x4", "gone 5", "gone 6", "x7", "x8"])
        #expect(lines.map(\.oldLine) == [1, nil, nil, 2, 3, 4, 5, 6, 7, 8])
        #expect(lines.map(\.newLine) == [1, 2, 3, 4, 5, 6, nil, nil, 7, 8])
    }

    /// Refuses contents that don't match the diff, as when the file changed on GitHub after the diff loaded.
    @Test("REQ-DIF-002: Rejects mismatched contents") func rejectsMismatchedContents() {
        #expect(Self.file.fullFile(headText: "1\n2\n3\n4\n5\n") == nil)
        #expect(Self.file.fullFile(headText: "1\n2\n") == nil)
    }

    /// Needs no contents for added and deleted files, which the diff already has in full, and fills a pure rename.
    @Test("REQ-DIF-002: Added deleted and renamed files") func addedDeletedAndRenamedFiles() throws {
        let files = DiffParser.parse(
            """
            diff --git a/new.txt b/new.txt
            new file mode 100644
            --- /dev/null
            +++ b/new.txt
            @@ -0,0 +1 @@
            +hello
            diff --git a/old.txt b/moved.txt
            similarity index 100%
            rename from old.txt
            rename to moved.txt

            """)
        #expect(!files[0].needsContentsForFullFile)
        let added = try #require(files[0].fullFile(headText: ""))
        #expect(added.isFullFile && added.hunks == files[0].hunks)

        #expect(files[1].needsContentsForFullFile)
        let renamed = try #require(files[1].fullFile(headText: "a\nb"))
        #expect(renamed.hunks.flatMap(\.lines).map(\.text) == ["a", "b"])
        #expect(renamed.commentableLines.isEmpty)
    }

    /// Finds the same line across the hunk and whole-file views, and a target's lines by number in either view.
    @Test("REQ-DIF-002, REQ-DIF-006: Matches lines across views") func matchesLinesAcrossViews() throws {
        let full = try #require(Self.file.fullFile(headText: Self.headText))
        let addition = try #require(Self.file.commentableLines.first { $0.kind == .addition })
        let match = try #require(full.lineID(matching: addition))
        #expect(full.line(withID: match)?.text == "FOUR")
        #expect(Self.file.lineID(matching: full.hunks[0].lines[0]) == nil)  // line 1 isn't in the hunks

        let target = try #require(Self.file.commentTarget(anchor: Self.file.commentableLines[0].id, cursor: addition.id))
        let range = try #require(full.lineIDs(for: target))
        #expect(full.hunks.flatMap(\.lines).filter { range.contains($0.id) }.map(\.text) == ["3", "4", "FOUR"])
    }

    /// Treats CRLF line endings and a missing final newline the same way the diff does.
    @Test("REQ-DIF-002: Line endings") func lineEndings() throws {
        let file = DiffParser.parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -2 +2 @@\n-b\r\n+B\r\n")[0]
        let full = try #require(file.fullFile(headText: "a\r\nB\r\nc"))
        #expect(full.hunks.flatMap(\.lines).map(\.text) == ["a\r", "b\r", "B\r", "c"])
    }
}

/// Read-only test of fetching file contents through `gh`, on the test PR `bmannakee/maser#1`.
///
/// Run with `MASER_LIVE_TESTS=1 swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MASER_LIVE_TESTS"] != nil))
struct LiveFullFileTests {
    /// Fetches README.md at the PR's head commit and expands its diff to the whole file.
    @Test("REQ-DIF-002, REQ-DIF-007: Expands real file") func expandsRealFile() async throws {
        let cli = GitHubCLI()
        let pr = try await cli.pullRequest(url: URL(string: "https://github.com/bmannakee/maser/pull/1")!)
        let file = try #require(try await cli.fileDiffs(for: pr).first { $0.path == "README.md" })
        let context = try await cli.reviewContext(for: pr)
        let text = try await cli.fileContents(of: pr, path: file.path, commitID: context.headCommitID)
        let full = try #require(file.fullFile(headText: text))
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
        let shown = full.cursorLines.count(where: { $0.newLine != nil })
        #expect(shown == lineCount)
        let limited = await #expect(throws: GitHubCLIError.self) {
            try await cli.fileContents(of: pr, path: file.path, commitID: context.headCommitID, maxBytes: 10)
        }
        #expect(limited != nil)
    }
}
