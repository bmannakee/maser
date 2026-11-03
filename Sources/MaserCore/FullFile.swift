// Expanding a file's diff to the whole file.
//
// GitHub's diff only has the changed hunks and a few lines of context around them. To show the whole file, the app
// fetches the file as of the PR's head commit and fills the stretches between hunks with its unchanged lines. Those
// filled-in lines are marked `isExpansion`, because GitHub won't take review comments on lines outside the diff.

import Foundation

extension FileDiff {
    /// Whether showing the whole file needs the file's contents from GitHub.
    ///
    /// Added and deleted files are already whole in the diff, and binary files have no lines to show.
    public var needsContentsForFullFile: Bool {
        !isBinary && status != .added && status != .deleted
    }

    /// Returns the whole file: the diff's hunks with the unchanged lines between them filled in.
    ///
    /// The filled-in stretches become hunks of their own, marked `isExpansion`, so hunk navigation still lands on the
    /// changes. Every hunk and line gets a new ID, in display order. Added and deleted files come back with just
    /// `isFullFile` set, since the diff already has every line.
    ///
    /// - Parameter headText: The file's contents at the PR's head commit. Unused for added and deleted files.
    /// - Returns: The full file, or `nil` if the diff doesn't fit `headText`, as when the file changed on GitHub after
    ///   the diff was loaded.
    public func fullFile(headText: String) -> FileDiff? {
        var full = self
        full.isFullFile = true
        guard needsContentsForFullFile else { return full }

        var headLines = headText.components(separatedBy: "\n")
        // A final newline ends the last line; it doesn't start another one.
        if headLines.last == "" { headLines.removeLast() }

        // Every line the diff has from the head version must match the fetched file.
        for line in hunks.flatMap(\.lines) {
            guard let number = line.newLine else { continue }
            guard number >= 1, number <= headLines.count, headLines[number - 1] == line.text else { return nil }
        }

        /// The unchanged head lines `from..<to`, numbered on both sides; `oldOffset` turns a new line number into an old one.
        func gap(from: Int, to: Int, oldOffset: Int) -> Hunk? {
            guard from < to else { return nil }
            let lines = (from..<to).map { number in
                DiffLine(
                    id: 0, kind: .context, text: headLines[number - 1], oldLine: number + oldOffset, newLine: number,
                    isExpansion: true)
            }
            return Hunk(id: 0, header: "", lines: lines, isExpansion: true)
        }

        var merged: [Hunk] = []
        // The next unchanged line on each side, after the hunks so far.
        var nextOld = 1
        var nextNew = 1
        for hunk in hunks {
            guard let range = HunkRange(hunk.header) else { return nil }
            // A count of 0 means the hunk has no lines on that side; its start is then the line *before* the hunk.
            let firstOld = range.oldCount == 0 ? range.oldStart + 1 : range.oldStart
            let firstNew = range.newCount == 0 ? range.newStart + 1 : range.newStart
            // The unchanged stretch must be the same length on both sides, or the diff is inconsistent.
            guard firstNew - nextNew == firstOld - nextOld, firstNew >= nextNew else { return nil }
            if let gap = gap(from: nextNew, to: firstNew, oldOffset: nextOld - nextNew) { merged.append(gap) }
            merged.append(hunk)
            nextOld = firstOld + range.oldCount
            nextNew = firstNew + range.newCount
        }
        if let gap = gap(from: nextNew, to: headLines.count + 1, oldOffset: nextOld - nextNew) { merged.append(gap) }

        // Renumber so IDs increase in display order, which line ranges and hunk navigation rely on.
        var nextID = 0
        full.hunks = merged.map { hunk in
            let id = nextID
            nextID += 1
            let lines = hunk.lines.map { line in
                defer { nextID += 1 }
                return line.with(id: nextID)
            }
            return Hunk(id: id, header: hunk.header, lines: lines, isExpansion: hunk.isExpansion)
        }
        return full
    }

    /// Finds the line in this diff that stands for the same line as one from another version of the diff.
    ///
    /// Used to keep the cursor in place when switching between the hunks and the whole file, which number lines
    /// differently.
    ///
    /// - Parameter line: A line from another `FileDiff` of the same file and diff.
    /// - Returns: The ID of the line with the same old and new line numbers and kind, or `nil` if there's none.
    public func lineID(matching line: DiffLine) -> Int? {
        for hunk in hunks {
            if let match = hunk.lines.first(where: {
                $0.oldLine == line.oldLine && $0.newLine == line.newLine && $0.kind == line.kind
            }) {
                return match.id
            }
        }
        return nil
    }

    /// Returns the line with an ID.
    ///
    /// - Parameter id: A `DiffLine.id` in this diff.
    /// - Returns: The line, or `nil` if no line has that ID.
    public func line(withID id: Int) -> DiffLine? {
        for hunk in hunks {
            if let line = hunk.lines.first(where: { $0.id == id }) { return line }
        }
        return nil
    }
}
