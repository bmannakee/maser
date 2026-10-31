import Foundation

public enum DiffSide: String, Codable, Hashable, Sendable {
    case left = "LEFT"
    case right = "RIGHT"
}

/// One file's changes within a unified diff.
public struct FileDiff: Identifiable, Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case added, deleted, modified, renamed
    }

    /// Path in the PR's head (for deleted files, the path that was removed).
    public var path: String
    /// Original path, set only for renames.
    public var oldPath: String?
    public var status: Status
    public var isBinary: Bool
    public var hunks: [Hunk]

    public var id: String { path }

    public init(path: String, oldPath: String? = nil, status: Status = .modified, isBinary: Bool = false, hunks: [Hunk] = []) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
        self.isBinary = isBinary
        self.hunks = hunks
    }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .addition } } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .deletion } } }

    /// ID of the diff line a review comment anchors to (`side` + `line` as GitHub reports them).
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

public struct Hunk: Identifiable, Hashable, Sendable {
    public let id: Int
    /// The full `@@ -a,b +c,d @@ context` line.
    public let header: String
    public var lines: [DiffLine]
}

public struct DiffLine: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case context, addition, deletion
        /// `\ No newline at end of file`
        case noNewlineMarker
    }

    /// Unique within its file; stable for a given diff.
    public let id: Int
    public let kind: Kind
    /// Line content without the leading `+`/`-`/space marker.
    public let text: String
    public let oldLine: Int?
    public let newLine: Int?
}

public enum DiffParser {
    /// Parses `git diff`-style unified output (as produced by `gh pr diff`) into per-file diffs.
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var file: FileDiff?
        var nextID = 0
        var inHunk = false
        var oldLine = 0, newLine = 0
        var oldRemaining = 0, newRemaining = 0

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
                file!.oldPath = String(line.dropFirst("rename from ".count))
                file!.status = .renamed
            } else if line.hasPrefix("rename to ") {
                file!.path = String(line.dropFirst("rename to ".count))
            } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
                file!.isBinary = true
            } else if line.hasPrefix("--- ") {
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

    /// `diff --git a/foo b/foo` → `foo`, when both sides match (the common, unambiguous case).
    static func pathFromGitHeader(_ line: String) -> String? {
        let rest = line.dropFirst("diff --git ".count)
        guard rest.hasPrefix("a/"), rest.count % 2 == 1 else { return nil }
        let half = (rest.count - 1) / 2
        let a = rest.prefix(half), b = rest.suffix(half)
        guard rest[rest.index(rest.startIndex, offsetBy: half)] == " ",
              b.hasPrefix("b/"), a.dropFirst(2) == b.dropFirst(2)
        else { return nil }
        return String(a.dropFirst(2))
    }

    static func stripPathPrefix(_ path: Substring, _ prefix: String) -> String {
        // git appends a tab after names containing spaces.
        var path = path
        while path.last == "\t" { path = path.dropLast() }
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : String(path)
    }
}

struct HunkRange {
    let oldStart: Int, oldCount: Int
    let newStart: Int, newCount: Int

    /// Parses `@@ -oldStart[,oldCount] +newStart[,newCount] @@ ...`.
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

    private static func pair(_ s: Substring) -> (Int, Int)? {
        let numbers = s.split(separator: ",", omittingEmptySubsequences: false)
        guard let start = Int(numbers[0]) else { return nil }
        guard numbers.count > 1 else { return (start, 1) }
        guard let count = Int(numbers[1]) else { return nil }
        return (start, count)
    }
}
