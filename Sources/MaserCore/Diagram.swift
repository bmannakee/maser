// A diagram the review agent drew, and the checks Maser makes before and after showing it.
//
// The agent sends a diagram through the `show_diagram` tool: Mermaid source, a title, and for each element its source
// lines and whether the PR changed it. `Diagram.sourceProblem` refuses source that could reach outside the picture
// (click handlers, links, remote styles) before it's rendered (RC-28). `DiagramGrounding` then checks what can be
// checked mechanically (RC-29): every citation against the checkout, and every change mark against the diff.

import Foundation

/// A diagram from the review agent.
public struct Diagram: Codable, Hashable, Sendable {
    /// The diagram's source language.
    public enum Format: String, Codable, Hashable, Sendable {
        /// Mermaid, rendered by the bundled Pele.
        case mermaid
        /// Graphviz DOT; planned, not rendered yet.
        case dot
    }

    /// Whether the PR changed an element.
    public enum Change: String, Codable, Hashable, Sendable {
        case added, removed, changed, unchanged
    }

    /// One element of the diagram, as the agent describes it.
    public struct Element: Codable, Hashable, Sendable {
        /// The element's ID in the rendered diagram: a state or node's name in the source, or `edgeN` for the Nth edge.
        public let id: String
        /// Where it comes from, as `path:start-end` or `path:line` at the head commit; for a removed element, the old
        /// lines.
        public let citation: String?
        /// Whether the PR changed it.
        public let change: Change?

        /// Creates an element.
        public init(id: String, citation: String? = nil, change: Change? = nil) {
            self.id = id
            self.citation = citation
            self.change = change
        }
    }

    /// The diagram's title.
    public let title: String
    /// The source language.
    public let format: Format
    /// The source.
    public let source: String
    /// What the agent says about each element.
    public let elements: [Element]

    /// Creates a diagram.
    public init(title: String, format: Format, source: String, elements: [Element] = []) {
        self.title = title
        self.format = format
        self.source = source
        self.elements = elements
    }

    /// The most source Maser renders, which is also Pele's own limit.
    public static let maxSourceLength = 50_000

    /// Reads a diagram from the `show_diagram` tool's arguments.
    ///
    /// - Parameter arguments: The JSON object the agent sent.
    /// - Returns: The diagram.
    /// - Throws: `DecodingError` if it's missing the title, format or source, or has an unknown format or change.
    public static func decode(toolArguments arguments: String) throws -> Diagram {
        /// The arguments, where `elements` is optional.
        struct Arguments: Decodable {
            let title: String
            let format: Format
            let source: String
            let elements: [Element]?
        }
        let decoded = try JSONDecoder().decode(Arguments.self, from: Data(arguments.utf8))
        return Diagram(title: decoded.title, format: decoded.format, source: decoded.source, elements: decoded.elements ?? [])
    }

    /// Why the source mustn't be rendered, if it mustn't.
    ///
    /// Refuses what could make the picture act or reach out: Mermaid's `click` directive (callbacks and links),
    /// `href`, `url(`, `javascript:`, HTML tags, and `%%{init}` directives, which can change the renderer's settings.
    /// Also refuses DOT, which isn't rendered yet, empty source, and source over `maxSourceLength`.
    ///
    /// - Returns: A sentence for the agent and the user, or nil if the source may be rendered.
    public var sourceProblem: String? {
        guard format == .mermaid else { return "Only Mermaid diagrams can be shown so far; DOT is planned." }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "The diagram is empty." }
        guard source.count <= Self.maxSourceLength else {
            return "The diagram is too long (\(source.count) characters; the most is \(Self.maxSourceLength))."
        }
        let lowered = source.lowercased()
        let lines = lowered.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(where: { $0.hasPrefix("click ") || $0 == "click" }) {
            return "Diagrams can't use click: the canvas doesn't run actions or open links."
        }
        for (pattern, what) in [
            ("href", "links"), ("url(", "remote styles"), ("javascript:", "scripts"), ("<script", "scripts"),
            ("<img", "images"), ("<a ", "links"), ("%%{", "renderer settings"), ("<iframe", "frames"),
        ] where lowered.contains(pattern) {
            return "Diagrams can't contain \(what) (found \"\(pattern)\")."
        }
        return nil
    }
}

/// Source lines an element cites: a path and a range of lines.
public struct Citation: Equatable, Sendable {
    /// The path, relative to the repository's root.
    public let path: String
    /// The lines, first to last.
    public let lines: ClosedRange<Int>

    /// Parses `path:start-end` or `path:line`.
    ///
    /// Fails for anything else, including an absolute path, a path with `..`, or lines that don't count up from 1.
    ///
    /// - Parameter text: The citation as the agent wrote it.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let path = String(trimmed[..<colon])
        let range = trimmed[trimmed.index(after: colon)...].split(separator: "-", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), (1...2).contains(range.count),
            let start = Int(range[0]), let end = Int(range.last ?? ""), start >= 1, end >= start
        else { return nil }
        self.path = path
        lines = start...end
    }
}

/// What the grounding check found about one element.
public struct ElementFinding: Codable, Hashable, Sendable {
    /// The element's ID.
    public let id: String
    /// What's wrong with it, as a sentence; empty if nothing is.
    public let problems: [String]
}

/// Checks a diagram's citations and change marks against the checkout and the diff.
public enum DiagramGrounding {
    /// Checks every element of a diagram.
    ///
    /// - A citation must parse, name a file in the checkout, and stay within its lines. A removed element's citation
    ///   names old lines, so it's checked against the diff's removed lines instead.
    /// - An element marked added or changed must cite lines the PR added; one marked removed, lines it removed.
    /// - An element marked unchanged, or not marked, mustn't cite lines the PR added.
    /// - An element must be in the rendered diagram, when its IDs are known.
    ///
    /// - Parameters:
    ///   - diagram: The diagram.
    ///   - checkout: The folder holding the head commit.
    ///   - files: The PR's diff.
    ///   - renderedIDs: The element IDs the rendered SVG has, or nil to skip that check.
    /// - Returns: One finding per element the agent described, in order.
    public static func check(
        _ diagram: Diagram, checkout: URL, files: [FileDiff], renderedIDs: Set<String>? = nil
    ) -> [ElementFinding] {
        let added = Dictionary(
            files.map { file in
                (
                    file.path,
                    Set(
                        file.hunks.filter { !$0.isExpansion }.flatMap(\.lines).filter { $0.kind == .addition }.compactMap(
                            \.newLine))
                )
            }, uniquingKeysWith: { first, _ in first })
        let removed = Dictionary(
            files.map { file in
                (
                    file.oldPath ?? file.path,
                    Set(
                        file.hunks.filter { !$0.isExpansion }.flatMap(\.lines).filter { $0.kind == .deletion }.compactMap(
                            \.oldLine))
                )
            }, uniquingKeysWith: { first, _ in first })
        var lineCounts: [String: Int?] = [:]

        return diagram.elements.map { element in
            var problems: [String] = []
            if let renderedIDs, !renderedIDs.contains(element.id) {
                problems.append("isn't in the drawn diagram")
            }
            guard let text = element.citation else {
                if element.change != nil && element.change != .unchanged {
                    problems.append("is marked \(element.change?.rawValue ?? "") but cites no lines")
                }
                return ElementFinding(id: element.id, problems: problems)
            }
            guard let citation = Citation(text) else {
                problems.append("cites \"\(text)\", which isn't path:start-end in the repository")
                return ElementFinding(id: element.id, problems: problems)
            }
            if element.change == .removed {
                if removed[citation.path].map({ !$0.isDisjoint(with: citation.lines) }) != true {
                    problems.append("is marked removed, but the PR removes none of \(text)")
                }
                return ElementFinding(id: element.id, problems: problems)
            }
            if lineCounts[citation.path] == nil {
                lineCounts[citation.path] = .some(Self.lineCount(of: citation.path, in: checkout))
            }
            guard let count = lineCounts[citation.path] ?? nil else {
                problems.append("cites \(citation.path), which isn't in the checkout")
                return ElementFinding(id: element.id, problems: problems)
            }
            if citation.lines.upperBound > count {
                problems.append("cites lines up to \(citation.lines.upperBound), but \(citation.path) has \(count)")
            }
            let touchesAdded = added[citation.path].map { !$0.isDisjoint(with: citation.lines) } ?? false
            switch element.change {
            case .added?, .changed?:
                if !touchesAdded {
                    problems.append("is marked \(element.change?.rawValue ?? "") but the PR doesn't change \(text)")
                }
            case .unchanged?, nil:
                if touchesAdded,
                    !Self.survivesEdits(element.id, lines: citation.lines, in: files.first { $0.path == citation.path })
                {
                    problems.append("cites lines the PR changes but isn't marked as changed")
                }
            case .removed?:
                break
            }
            return ElementFinding(id: element.id, problems: problems)
        }
    }

    /// Whether an element on edited lines was left alone by the edit: its name is on each added line it cites, and on a
    /// removed line of the same hunk.
    ///
    /// One line can hold several elements, such as an enum's cases, and an edit to one of them doesn't change the
    /// others. Found by the 2026-11-12 evaluation, where unchanged states on an edited enum line were flagged.
    ///
    /// - Parameters:
    ///   - id: The element's name.
    ///   - lines: The lines it cites, at the head.
    ///   - file: The file's diff.
    /// - Returns: True if every added line it cites still names it, as a removed line in that hunk did.
    static func survivesEdits(_ id: String, lines: ClosedRange<Int>, in file: FileDiff?) -> Bool {
        guard let file else { return false }
        for hunk in file.hunks where !hunk.isExpansion {
            let removedText = hunk.lines.filter { $0.kind == .deletion }.map(\.text)
            for line in hunk.lines where line.kind == .addition && line.newLine.map(lines.contains) == true {
                guard names(id, in: line.text), removedText.contains(where: { names(id, in: $0) }) else { return false }
            }
        }
        return true
    }

    /// Whether text names an identifier as a whole word.
    ///
    /// - Parameters:
    ///   - id: The identifier.
    ///   - text: The text.
    /// - Returns: True if `id` occurs with no letter, digit or underscore on either side.
    static func names(_ id: String, in text: String) -> Bool {
        guard !id.isEmpty else { return false }
        let isWord = { (character: Character) in character.isLetter || character.isNumber || character == "_" }
        var search = text[...]
        while let range = search.range(of: id) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before.map(isWord) ?? false) && !(after.map(isWord) ?? false) { return true }
            search = text[range.upperBound...]
        }
        return false
    }

    /// Counts a file's lines in the checkout, refusing paths that lead outside it.
    ///
    /// - Parameters:
    ///   - path: The path, relative to the checkout.
    ///   - checkout: The checkout's folder.
    /// - Returns: The number of lines, or nil if it isn't a readable file inside the checkout.
    public static func lineCount(of path: String, in checkout: URL) -> Int? {
        let root = checkout.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let file = checkout.appending(path: path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path(percentEncoded: false).hasPrefix(root.hasSuffix("/") ? root : root + "/"),
            let text = try? String(contentsOf: file, encoding: .utf8)
        else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // A final newline doesn't start another line.
        return text.hasSuffix("\n") ? lines.count - 1 : lines.count
    }
}
