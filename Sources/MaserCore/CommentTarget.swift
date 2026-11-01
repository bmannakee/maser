import Foundation

extension DiffLine {
    /// The side of the diff a comment on this line attaches to (`nil`: can't be commented on).
    public var commentSide: DiffSide? {
        switch kind {
        case .deletion: .left
        case .addition, .context: .right
        case .noNewlineMarker: nil
        }
    }

    /// The line number GitHub uses for a comment on this line, on `commentSide`.
    public var commentLine: Int? {
        switch kind {
        case .deletion: oldLine
        case .addition, .context: newLine
        case .noNewlineMarker: nil
        }
    }
}

/// A line, or range of lines within one hunk, to start a review thread on — in GitHub's terms.
public struct CommentTarget: Hashable, Sendable {
    public let path: String
    public let side: DiffSide
    public let line: Int
    /// Set for multi-line comments.
    public let startSide: DiffSide?
    public let startLine: Int?
    /// The diff line IDs covered, for highlighting.
    public let lineIDs: ClosedRange<Int>

    /// e.g. "line 12", "old line 7", "lines 10–14".
    public var description: String {
        func number(_ side: DiffSide, _ line: Int) -> String { side == .left ? "old \(line)" : "\(line)" }
        if let startLine, let startSide {
            return "lines \(number(startSide, startLine))–\(number(side, line))"
        }
        return side == .left ? "old line \(line)" : "line \(line)"
    }
}

extension FileDiff {
    /// Lines that can carry a comment, in display order.
    public var commentableLines: [DiffLine] {
        hunks.flatMap { $0.lines.filter { $0.commentSide != nil } }
    }

    /// The hunk containing a line.
    public func hunk(containing lineID: Int) -> Hunk? {
        hunks.first { hunk in hunk.lines.contains { $0.id == lineID } }
    }

    /// The selected line IDs from `anchor` (where a range selection started) to `cursor`.
    /// GitHub requires a multi-line comment to stay within one hunk, so the range is clipped to the cursor's hunk.
    public func selectionRange(anchor: Int?, cursor: Int) -> ClosedRange<Int> {
        guard let anchor, anchor != cursor, let hunk = hunk(containing: cursor) else { return cursor...cursor }
        let ids = hunk.lines.filter { $0.commentSide != nil }.map(\.id)
        guard let first = ids.first, let last = ids.last else { return cursor...cursor }
        let clipped = min(max(anchor, first), last)
        return min(clipped, cursor)...max(clipped, cursor)
    }

    /// What a new comment on the selection would attach to.
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
