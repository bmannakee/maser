// The unified-diff model and parser behind the Files view.
//
// `DiffParser` turns the output of `gh pr diff` into `FileDiff` values: one per file, each split into hunks of
// numbered lines. Line numbers on both sides let review comments, which GitHub anchors by side and line number,
// be placed on the right row.

import Foundation

/// Which version of a file a review comment is anchored to, using GitHub's `LEFT`/`RIGHT` names.
public enum DiffSide: String, Codable, Hashable, Sendable {
    /// The base version: deleted and unchanged lines, numbered as before the change.
    case left = "LEFT"
    /// The head version: added and unchanged lines, numbered as after the change.
    case right = "RIGHT"
}

/// One file's changes within a unified diff.
public struct FileDiff: Identifiable, Hashable, Sendable {
    /// How the PR changes the file.
    public enum Status: String, Hashable, Sendable {
        case added, deleted, modified, renamed
    }

    /// Path in the PR's head (for deleted files, the path that was removed).
    public var path: String
    /// Original path, set only for renames.
    public var oldPath: String?
    /// How the file changed.
    public var status: Status
    /// Whether git reported the file as binary; binary files have no hunks.
    public var isBinary: Bool
    /// The file's hunks, in diff order.
    ///
    /// In a full-file view (`isFullFile`), unchanged stretches between them are hunks too, marked `isExpansion`.
    public var hunks: [Hunk]
    /// Whether this is the whole file, with the unchanged lines between hunks filled in.
    ///
    /// See `fullFile(headText:)`.
    public var isFullFile = false

    /// The file's path, which is unique within one diff.
    public var id: String { path }

    /// Creates a file diff.
    ///
    /// - Parameters:
    ///   - path: Path in the PR's head, or the removed path for a deleted file.
    ///   - oldPath: The original path, for renames only.
    ///   - status: How the file changed.
    ///   - isBinary: Whether the file is binary.
    ///   - hunks: The file's hunks, in diff order.
    public init(path: String, oldPath: String? = nil, status: Status = .modified, isBinary: Bool = false, hunks: [Hunk] = []) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.isBinary = isBinary
        self.hunks = hunks
    }

    /// Number of added lines in the file.
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .addition } } }
    /// Number of deleted lines in the file.
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .deletion } } }

    /// Finds the diff line a review comment anchors to.
    ///
    /// - Parameters:
    ///   - side: The side GitHub reports for the comment.
    ///   - line: The line number on that side, as GitHub reports it.
    /// - Returns: The `DiffLine.id` of the first matching line, or `nil` if that line isn't in the diff.
    public func lineID(side: DiffSide, line: Int) -> Int? {
        for hunk in hunks {
            for diffLine in hunk.lines {
                switch side {
                case .right where diffLine.newLine == line: return diffLine.id
                case .left where diffLine.oldLine == line: return diffLine.id
                default: continue
                }
            }
        }
        return nil
    }
}

/// A contiguous block of changes within a file, introduced by an `@@` header.
public struct Hunk: Identifiable, Hashable, Sendable {
    /// Unique among the hunks and lines of one file.
    public let id: Int
    /// The full `@@ -a,b +c,d @@ context` line; empty for an expansion.
    public let header: String
    /// The hunk's lines, in diff order.
    public var lines: [DiffLine]
    /// Whether this is a stretch of unchanged lines filled in from the whole file, rather than part of GitHub's diff.
    public let isExpansion: Bool

    /// Creates a hunk.
    ///
    /// - Parameters:
    ///   - id: Unique among the hunks and lines of the file.
    ///   - header: The `@@` line, or empty for an expansion.
    ///   - lines: The hunk's lines.
    ///   - isExpansion: Whether the lines were filled in from the whole file.
    init(id: Int, header: String, lines: [DiffLine], isExpansion: Bool = false) {
        self.id = id
        self.header = header
        self.lines = lines
        self.isExpansion = isExpansion
    }
}

/// One line of a hunk, with its line numbers on each side.
public struct DiffLine: Identifiable, Hashable, Sendable {
    /// What the line represents in the diff.
    public enum Kind: Hashable, Sendable {
        case context, addition, deletion
        /// `\ No newline at end of file`
        case noNewlineMarker
    }

    /// Unique within its file, and increasing in display order.
    public let id: Int
    /// Whether the line is context, added, deleted, or a no-newline marker.
    public let kind: Kind
    /// Line content without the leading `+`/`-`/space marker.
    public let text: String
    /// Line number in the base version; `nil` for additions and markers.
    public let oldLine: Int?
    /// Line number in the head version; `nil` for deletions and markers.
    public let newLine: Int?
    /// Whether the line is an unchanged line filled in from the whole file, outside GitHub's diff.
    ///
    /// GitHub only accepts review comments on lines in the diff, so these can't be commented on.
    public let isExpansion: Bool

    /// Creates a diff line.
    ///
    /// - Parameters:
    ///   - id: Unique within the file, increasing in display order.
    ///   - kind: What the line represents.
    ///   - text: The content, without the diff marker.
    ///   - oldLine: The line number in the base version, if the line exists there.
    ///   - newLine: The line number in the head version, if the line exists there.
    ///   - isExpansion: Whether the line was filled in from the whole file.
    init(id: Int, kind: Kind, text: String, oldLine: Int?, newLine: Int?, isExpansion: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.oldLine = oldLine
        self.newLine = newLine
        self.isExpansion = isExpansion
    }

    /// Returns a copy of the line with a different ID.
    func with(id: Int) -> DiffLine {
        DiffLine(id: id, kind: kind, text: text, oldLine: oldLine, newLine: newLine, isExpansion: isExpansion)
    }
}

/// Parses unified diff text into `FileDiff` values.
public enum DiffParser {
    /// Parses `git diff`-style unified output (as produced by `gh pr diff`) into per-file diffs.
    ///
    /// Parsing is lenient: text before the first `diff --git` line and lines past a hunk's stated length are ignored,
    /// and a malformed `@@` header doesn't start a hunk.
    ///
    /// - Parameter text: The whole diff.
    /// - Returns: One `FileDiff` per `diff --git` section, in diff order.
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var file: FileDiff?
        var nextID = 0
        var inHunk = false
        var oldLine = 0, newLine = 0
        var oldRemaining = 0, newRemaining = 0

        /// Adds a line to the current file's last hunk and gives it the next ID.
        ///
        /// Only called once a hunk has started, so `file` and its last hunk exist.
        func append(_ kind: DiffLine.Kind, _ text: String, old: Int?, new: Int?) {
            file!.hunks[file!.hunks.count - 1].lines.append(
                DiffLine(id: nextID, kind: kind, text: text, oldLine: old, newLine: new)
            )
            nextID += 1
        }

        // Foundation splitting so CRLF content lines don't merge into one Character.
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") {
                if let file { files.append(file) }
                file = FileDiff(path: pathFromGitHeader(line) ?? "")
                inHunk = false
                continue
            }
            guard file != nil else { continue }

            if line.hasPrefix("@@ "), let range = HunkRange(line) {
                inHunk = true
                (oldLine, newLine) = (range.oldStart, range.newStart)
                (oldRemaining, newRemaining) = (range.oldCount, range.newCount)
                file!.hunks.append(Hunk(id: nextID, header: line, lines: []))
                nextID += 1
                continue
            }

            if inHunk {
                if line.hasPrefix("\\") {
                    append(.noNewlineMarker, String(line.dropFirst(2)), old: nil, new: nil)
                    continue
                }
                // Counts tell us where the hunk ends; anything past that (e.g. a trailing blank line) isn't content.
                guard oldRemaining > 0 || newRemaining > 0 else { continue }
                let content = String(line.dropFirst())
                switch line.first {
                case "+":
                    append(.addition, content, old: nil, new: newLine)
                    newLine += 1; newRemaining -= 1
                case "-":
                    append(.deletion, content, old: oldLine, new: nil)
                    oldLine += 1; oldRemaining -= 1
                default:
                    append(.context, content, old: oldLine, new: newLine)
                    oldLine += 1; newLine += 1
                    oldRemaining -= 1; newRemaining -= 1
                }
                continue
            }

            // Extended header lines between `diff --git` and the first hunk.
            if line.hasPrefix("new file mode") {
                file!.status = .added
            } else if line.hasPrefix("deleted file mode") {
                file!.status = .deleted
            } else if line.hasPrefix("rename from ") {
                file!.oldPath = unquotedPath(line.dropFirst("rename from ".count))
                file!.status = .renamed
            } else if line.hasPrefix("rename to ") {
                file!.path = unquotedPath(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                file!.isBinary = true
            } else if line.hasPrefix("--- ") {
                // Only a fallback: the `+++` line names the head path, which is what `path` means.
                let path = stripPathPrefix(line.dropFirst(4), "a/")
                if file!.path.isEmpty, path != "/dev/null" { file!.path = path }
            } else if line.hasPrefix("+++ ") {
                let path = stripPathPrefix(line.dropFirst(4), "b/")
                if path != "/dev/null" { file!.path = path }
            }
        }
        if let file { files.append(file) }
        return files
    }

    /// Extracts the path from a `diff --git` header line.
    ///
    /// `diff --git a/foo b/foo` → `foo`, when both sides match (the common, unambiguous case). Paths with spaces
    /// make the header ambiguous when the sides differ, so the parser then relies on later header lines instead.
    /// Quoted paths (`"a/caf\303\251" "b/caf\303\251"`) aren't ambiguous, so the `b/` path is returned unquoted.
    ///
    /// - Parameter line: The full header line.
    /// - Returns: The path, or `nil` if the two sides differ or the line isn't in the expected form.
    static func pathFromGitHeader(_ line: String) -> String? {
        let rest = line.dropFirst("diff --git ".count)
        if rest.contains("\"") {
            return quotedHeaderPath(rest)
        }
        guard rest.hasPrefix("a/"), rest.count % 2 == 1 else { return nil }
        let half = (rest.count - 1) / 2
        let a = rest.prefix(half), b = rest.suffix(half)
        guard rest[rest.index(rest.startIndex, offsetBy: half)] == " ",
            b.hasPrefix("b/"), a.dropFirst(2) == b.dropFirst(2)
        else { return nil }
        return String(a.dropFirst(2))
    }

    /// Cleans up the path from a `---` or `+++` line.
    ///
    /// - Parameters:
    ///   - path: The text after `--- ` or `+++ `.
    ///   - prefix: The side's prefix to drop, `a/` or `b/`.
    /// - Returns: The path without trailing tabs or the prefix; `/dev/null` comes back unchanged.
    static func stripPathPrefix(_ path: Substring, _ prefix: String) -> String {
        // git appends a tab after names containing spaces.
        var path = path
        while path.last == "\t" { path = path.dropLast() }
        let unquoted = unquotedPath(path)
        return unquoted.hasPrefix(prefix) ? String(unquoted.dropFirst(prefix.count)) : unquoted
    }

    /// Returns the `b/` path from the part of a `diff --git` header after `diff --git `, when a path is quoted.
    ///
    /// - Parameter rest: Two paths separated by a space, at least one of them quoted.
    /// - Returns: The second path without quotes or its `b/` prefix, or `nil` if the line isn't in the expected form.
    private static func quotedHeaderPath(_ rest: Substring) -> String? {
        let second: Substring
        if rest.first == "\"" {
            guard let end = closingQuote(in: rest), rest[rest.index(after: end)...].first == " " else { return nil }
            second = rest[rest.index(end, offsetBy: 2)...]
        } else {
            // The first path is plain, so the second must be the quoted one.
            guard let start = rest.range(of: " \"b/", options: .backwards) else { return nil }
            second = rest[rest.index(after: start.lowerBound)...]
        }
        let path = unquotedPath(second)
        return path.hasPrefix("b/") ? String(path.dropFirst(2)) : nil
    }

    /// Finds the quote that closes a quoted path.
    ///
    /// - Parameter text: Text starting with `"`.
    /// - Returns: The index of the first unescaped `"` after the opening one, or `nil` if there isn't one.
    private static func closingQuote(in text: Substring) -> Substring.Index? {
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            switch text[index] {
            case "\\": index = text.index(after: index)
            case "\"": return index
            default: break
            }
            if index < text.endIndex { index = text.index(after: index) }
        }
        return nil
    }

    /// Undoes git's quoting of a path with unusual characters.
    ///
    /// git wraps such paths in double quotes and writes C-style escapes: `\"`, `\\`, `\t`, `\n` and the like, and
    /// non-ASCII bytes as three octal digits (`caf\303\251` is "café" in UTF-8).
    ///
    /// - Parameter text: A path as it appears in a diff header, quoted or not.
    /// - Returns: The path with quotes and escapes removed; an unquoted path comes back unchanged.
    static func unquotedPath(_ text: Substring) -> String {
        guard text.count >= 2, text.first == "\"", text.last == "\"" else { return String(text) }
        let inner = Array(text.dropFirst().dropLast().utf8)
        var bytes: [UInt8] = []
        var index = 0
        while index < inner.count {
            let byte = inner[index]
            index += 1
            guard byte == UInt8(ascii: "\\"), index < inner.count else {
                bytes.append(byte)
                continue
            }
            let escaped = inner[index]
            index += 1
            switch escaped {
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                // Up to three octal digits make one byte.
                var value = UInt32(escaped - UInt8(ascii: "0"))
                for _ in 0..<2 where index < inner.count && (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(inner[index]) {
                    value = value * 8 + UInt32(inner[index] - UInt8(ascii: "0"))
                    index += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            default: bytes.append(escaped)  // `\"`, `\\`, and anything unexpected, taken literally
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// The line ranges from a hunk's `@@` header.
struct HunkRange {
    let oldStart: Int, oldCount: Int
    let newStart: Int, newCount: Int

    /// Parses `@@ -oldStart[,oldCount] +newStart[,newCount] @@ ...`.
    ///
    /// A missing count means 1, as in unified diff format.
    ///
    /// - Parameter line: The hunk header line.
    init?(_ line: String) {
        guard line.hasPrefix("@@ -") else { return nil }
        let afterOpen = line.index(line.startIndex, offsetBy: 4)
        guard let close = line.range(of: " @@", range: afterOpen..<line.endIndex) else { return nil }
        let parts = line[afterOpen..<close.lowerBound].split(separator: " ")
        guard parts.count == 2, parts[1].hasPrefix("+"),
            let old = Self.pair(parts[0]), let new = Self.pair(parts[1].dropFirst())
        else { return nil }
        (oldStart, oldCount) = old
        (newStart, newCount) = new
    }

    /// Parses `start[,count]` into a start and count, defaulting the count to 1.
    ///
    /// - Parameter s: The range text without its leading `-` or `+`.
    /// - Returns: The start and count, or `nil` if either isn't a number.
    private static func pair(_ s: Substring) -> (Int, Int)? {
        let numbers = s.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(numbers[0]) else { return nil }
        guard numbers.count > 1 else { return (start, 1) }
        guard let count = Int(numbers[1]) else { return nil }
        return (start, count)
    }
}
