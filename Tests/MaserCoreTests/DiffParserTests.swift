// Tests for `DiffParser`, which turns `gh pr diff` output into `FileDiff`s.
//
// Covers line numbering on both sides, multiple files and hunks, file statuses (added, deleted, renamed, binary),
// "No newline" markers, hunk headers and paths in `diff --git` headers.

import Testing

@testable import MaserCore

/// Tests for parsing unified diffs into files, hunks and numbered lines.
@Suite struct DiffParserTests {
    /// Numbers old and new lines through a hunk, treats a deleted `--- …` line as content rather than a file header, and
    /// maps side and line number back to a line ID.
    @Test func modifiedFileLineNumbers() throws {
        let diff = """
            diff --git a/src/app.swift b/src/app.swift
            index 111..222 100644
            --- a/src/app.swift
            +++ b/src/app.swift
            @@ -10,4 +10,4 @@ struct App {
             let a = 1
            -let b = 2
            +let b = 3
            +let c = 4
             let d = 5
            --- deleted line that looks like a file header
            """
        let files = DiffParser.parse(diff)
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.path == "src/app.swift")
        #expect(file.status == .modified)
        #expect(file.hunks.count == 1)

        let lines = file.hunks[0].lines
        #expect(lines.map(\.kind) == [.context, .deletion, .addition, .addition, .context, .deletion])
        #expect(lines.map(\.oldLine) == [10, 11, nil, nil, 12, 13])
        #expect(lines.map(\.newLine) == [10, nil, 11, 12, 13, nil])
        #expect(lines[5].text == "-- deleted line that looks like a file header")
        #expect(file.additions == 2)
        #expect(file.deletions == 2)

        #expect(file.lineID(side: .right, line: 12) == lines[3].id)
        #expect(file.lineID(side: .left, line: 11) == lines[1].id)
        #expect(file.lineID(side: .right, line: 99) == nil)
    }

    /// Splits files and hunks, restarts numbering at each hunk header, and gives every hunk and line a unique ID.
    @Test func multipleFilesAndHunks() {
        let diff = """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1 +1 @@
            -old
            +new
            @@ -20,2 +20,2 @@
             same
            -x
            +y
            diff --git a/b.txt b/b.txt
            --- a/b.txt
            +++ b/b.txt
            @@ -5,0 +6,1 @@
            +inserted

            """
        let files = DiffParser.parse(diff)
        #expect(files.map(\.path) == ["a.txt", "b.txt"])
        #expect(files[0].hunks.count == 2)
        #expect(files[0].hunks[1].lines.map(\.newLine) == [20, nil, 21])
        // Trailing blank line after the last hunk is not treated as content.
        #expect(files[1].hunks[0].lines.count == 1)
        #expect(files[1].hunks[0].lines[0].newLine == 6)

        let allIDs = files.flatMap { $0.hunks.flatMap { [$0.id] + $0.lines.map(\.id) } }
        #expect(Set(allIDs).count == allIDs.count)
    }

    /// Detects each file status; a pure rename has no hunks and a binary file counts as modified.
    @Test func addedDeletedRenamedBinary() {
        let diff = """
            diff --git a/new.txt b/new.txt
            new file mode 100644
            index 0000000..e69de29
            --- /dev/null
            +++ b/new.txt
            @@ -0,0 +1,2 @@
            +one
            +two
            diff --git a/gone.txt b/gone.txt
            deleted file mode 100644
            --- a/gone.txt
            +++ /dev/null
            @@ -1 +0,0 @@
            -bye
            diff --git a/old/name.txt b/new/name.txt
            similarity index 100%
            rename from old/name.txt
            rename to new/name.txt
            diff --git a/logo.png b/logo.png
            index 1..2 100644
            Binary files a/logo.png and b/logo.png differ
            """
        let files = DiffParser.parse(diff)
        #expect(files.map(\.path) == ["new.txt", "gone.txt", "new/name.txt", "logo.png"])
        #expect(files.map(\.status) == [.added, .deleted, .renamed, .modified])
        #expect(files[0].hunks[0].lines.map(\.newLine) == [1, 2])
        #expect(files[1].hunks[0].lines.map(\.oldLine) == [1])
        #expect(files[2].oldPath == "old/name.txt")
        #expect(files[2].hunks.isEmpty)
        #expect(files[3].isBinary)
    }

    /// Keeps `\ No newline at end of file` as its own line kind, without the leading backslash.
    @Test func noNewlineMarker() {
        let diff = """
            diff --git a/f b/f
            --- a/f
            +++ b/f
            @@ -1 +1 @@
            -a
            \\ No newline at end of file
            +b
            \\ No newline at end of file
            """
        let lines = DiffParser.parse(diff)[0].hunks[0].lines
        #expect(lines.map(\.kind) == [.deletion, .noNewlineMarker, .addition, .noNewlineMarker])
        #expect(lines[1].text == "No newline at end of file")
    }

    /// Parses a hunk header, defaulting an omitted count to 1, and rejects a malformed one.
    @Test func hunkRange() throws {
        let range = try #require(HunkRange("@@ -3,7 +4 @@ func x() @@ y"))
        #expect((range.oldStart, range.oldCount, range.newStart, range.newCount) == (3, 7, 4, 1))
        #expect(HunkRange("@@ garbage @@") == nil)
    }

    /// Unquotes paths git writes in quotes, with octal UTF-8 bytes and C escapes, in every header line.
    @Test func quotedPaths() {
        let diff = #"""
            diff --git "a/caf\303\251.txt" "b/caf\303\251.txt"
            index 1..2 100644
            --- "a/caf\303\251.txt"
            +++ "b/caf\303\251.txt"
            @@ -1 +1 @@
            -a
            +b
            diff --git "a/tab\there.txt" "b/new \"name\".txt"
            similarity index 100%
            rename from "tab\there.txt"
            rename to "new \"name\".txt"
            diff --git a/plain.png "b/\303\251.png"
            Binary files a/plain.png and "b/\303\251.png" differ
            """#
        let files = DiffParser.parse(diff)
        #expect(files.map(\.path) == ["café.txt", #"new "name".txt"#, "é.png"])
        #expect(files[1].oldPath == "tab\there.txt")
        #expect(files[2].isBinary)
        #expect(DiffParser.unquotedPath(#""back\\slash""#) == #"back\slash"#)
        #expect(DiffParser.unquotedPath("not quoted") == "not quoted")
    }

    /// Reads a path containing spaces from a `diff --git` header, and gives up when the two paths differ.
    @Test func gitHeaderPath() {
        #expect(DiffParser.pathFromGitHeader("diff --git a/with space.txt b/with space.txt") == "with space.txt")
        #expect(DiffParser.pathFromGitHeader("diff --git a/x b/y") == nil)
    }
}
