// Mapping diff lines and selections to the places GitHub lets you start a review thread.
//
// GitHub addresses an inline comment by path, side (`LEFT` for the old file, `RIGHT` for the new) and line number on that
// side, plus a start side and line for a range. The extensions here translate the app's diff lines and cursor/anchor
// selections into a `CommentTarget` in those terms, which `GitHubCLI.addReviewThread` sends to GitHub.

import Foundation

extension DiffLine {
    /// The side of the diff a comment on this line attaches to; `nil` when the line can't be commented on.
    public var commentSide: DiffSide? {
        switch kind {
        case .deletion: .left
        case .addition, .context: .right
        case .noNewlineMarker: nil
        }
    }

    /// The line number GitHub uses for a comment on this line, counted on `commentSide`.
    ///
    /// Deletions use the old file's line number; additions and context lines use the new file's. `nil` when the line
    /// can't be commented on.
    public var commentLine: Int? {
        switch kind {
        case .deletion: oldLine
        case .addition, .context: newLine
        case .noNewlineMarker: nil
        }
    }
}

/// A line, or range of lines within one hunk, to start a review thread on, in GitHub's terms.
public struct CommentTarget: Hashable, Sendable {
    /// The path of the file, relative to the repository root.
    public let path: String
    /// The side of the diff `line` is on.
    public let side: DiffSide
    /// The line to comment on: the last line, for a range.
    public let line: Int
    /// The side of the diff `startLine` is on; `nil` for a single-line comment.
    public let startSide: DiffSide?
    /// The first line of a multi-line comment; `nil` for a single-line comment.
    public let startLine: Int?
    /// The IDs of the diff lines the comment covers, for highlighting.
    public let lineIDs: ClosedRange<Int>

    /// A short label for the target, such as "line 12", "old line 7", "lines 10–14" or "old line 2 to line 3".
    public var description: String {
        Self.describe(side: side, line: line, startSide: startSide, startLine: startLine)
    }

    /// Labels a line or range in GitHub's terms, as `description` does; shared with review threads.
    ///
    /// - Parameters:
    ///   - side: The side of the diff `line` is on.
    ///   - line: The single line, or the last line of a range.
    ///   - startSide: The side `startLine` is on; `nil` means the same as `side`.
    ///   - startLine: The first line of a range; `nil` or equal to `line` (as GitHub reports single-line threads)
    ///     means a single line.
    /// - Returns: For example "line 12", "old line 7", "lines 10–14", "old lines 3–5" or "old line 2 to line 3".
    public static func describe(side: DiffSide, line: Int, startSide: DiffSide?, startLine: Int?) -> String {
        func single(_ side: DiffSide, _ line: Int) -> String { side == .left ? "old line \(line)" : "line \(line)" }
        let startSide = startSide ?? side
        guard let startLine, startLine != line || startSide != side else { return single(side, line) }
        if startSide == side {
            return side == .left ? "old lines \(startLine)–\(line)" : "lines \(startLine)–\(line)"
        }
        return "\(single(startSide, startLine)) to \(single(side, line))"
    }
}

extension FileDiff {
    /// The lines that can carry a comment, in display order.
    public var commentableLines: [DiffLine] {
        hunks.flatMap { $0.lines.filter { $0.commentSide != nil } }
    }

    /// Returns the hunk containing a line.
    ///
    /// - Parameter lineID: A `DiffLine.id`. Hunk header IDs aren't lines, so they match no hunk.
    /// - Returns: The hunk, or `nil` if no hunk in this file has the line.
    public func hunk(containing lineID: Int) -> Hunk? {
        hunks.first { hunk in hunk.lines.contains { $0.id == lineID } }
    }

    /// Returns the selected line IDs from `anchor` to `cursor`.
    ///
    /// GitHub requires a multi-line comment to stay within one hunk, so the anchor is clamped to the commentable lines of
    /// the cursor's hunk.
    ///
    /// - Parameters:
    ///   - anchor: The line ID where a range selection started, or `nil` when there's no range selection.
    ///   - cursor: The line ID of the cursor.
    /// - Returns: The selected IDs, in order; just `cursor` when there's no anchor or the cursor isn't in a hunk.
    public func selectionRange(anchor: Int?, cursor: Int) -> ClosedRange<Int> {
        guard let anchor, anchor != cursor, let hunk = hunk(containing: cursor) else { return cursor...cursor }
        let ids = hunk.lines.filter { $0.commentSide != nil }.map(\.id)
        guard let first = ids.first, let last = ids.last else { return cursor...cursor }
        let clipped = min(max(anchor, first), last)
        return min(clipped, cursor)...max(clipped, cursor)
    }

    /// Returns what a new comment on the selection would attach to.
    ///
    /// The selection is clipped as in `selectionRange(anchor:cursor:)`, then trimmed to its first and last commentable
    /// lines.
    ///
    /// - Parameters:
    ///   - anchor: The line ID where a range selection started, or `nil` when there's no range selection.
    ///   - cursor: The line ID of the cursor.
    /// - Returns: The target, or `nil` when the selection has no commentable line.
    public func commentTarget(anchor: Int?, cursor: Int) -> CommentTarget? {
        let range = selectionRange(anchor: anchor, cursor: cursor)
        let lines = commentableLines.filter { range.contains($0.id) }
        guard let first = lines.first, let last = lines.last,
            let side = last.commentSide, let line = last.commentLine,
            let startSide = first.commentSide, let startLine = first.commentLine
        else { return nil }
        let isRange = first.id != last.id
        return CommentTarget(
            path: path,
            side: side,
            line: line,
            startSide: isRange ? startSide : nil,
            startLine: isRange ? startLine : nil,
            lineIDs: first.id...last.id
        )
    }
}
