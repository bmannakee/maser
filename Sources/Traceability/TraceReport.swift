// The generated parts of docs/design/traceability.md, and the entry point that checks a repository.
//
// traceability.md mixes prose with tables generated from the other documents. Each generated table sits between
// `<!-- trace:begin NAME -->` and `<!-- trace:end NAME -->` markers. `TraceReport` renders the tables, rewrites them
// in place with `--write`, and otherwise reports a section that's missing or out of date.

import Foundation

/// The generated traceability tables, and a repository-level check.
public struct TraceReport: Sendable {
    /// The design documents and records the report is built from.
    let documents: DesignDocuments
    /// The tests in the repository.
    let tests: TestIndex

    /// The document holding the generated sections, relative to the repository root.
    static let traceabilityFile = "\(DesignDocuments.designDirectory)/traceability.md"

    /// The outcome of checking a repository.
    public struct Outcome: Sendable {
        /// Every problem found; the check passes when it's empty.
        public let problems: [Problem]
        /// A one-line count of what was checked, for the console.
        public let summary: String
        /// Whether `--write` changed traceability.md.
        public let rewrote: Bool
    }

    /// Checks a repository's traceability, optionally regenerating traceability.md first.
    ///
    /// - Parameters:
    ///   - root: The repository's root directory.
    ///   - write: Whether to rewrite the generated sections of traceability.md before checking.
    /// - Returns: The problems and a summary.
    /// - Throws: A file system error if a document or test file can't be read or written.
    public static func check(root: URL, write: Bool) throws -> Outcome {
        var report = TraceReport(documents: try DesignDocuments.load(root: root), tests: try TestIndex.load(root: root))
        var rewrote = false
        if write, let current = report.documents.texts[traceabilityFile] {
            let updated = report.splice(into: current)
            if updated != current {
                try updated.write(to: root.appending(path: traceabilityFile), atomically: true, encoding: .utf8)
                report = TraceReport(documents: try DesignDocuments.load(root: root), tests: report.tests)
                rewrote = true
            }
        }
        let problems = TraceChecker(documents: report.documents, tests: report.tests).problems() + report.staleSections()
        return Outcome(problems: problems, summary: report.summary, rewrote: rewrote)
    }

    // MARK: - Sections

    /// The generated sections by name, in the order they appear in traceability.md.
    var sections: [(name: String, body: String)] {
        [
            ("needs-to-requirements", needsToRequirements),
            ("hazards-to-controls", hazardsToControls),
            ("coverage", coverage),
        ]
    }

    /// A table of each user need and the requirements that serve it.
    var needsToRequirements: String {
        let requirements = documents.items(.requirement)
        var lines = ["| Need | Implemented requirements | Proposed |", "| --- | --- | --- |"]
        for need in documents.items(.need) {
            let serving = requirements.filter { DesignDocuments.ids(in: $0["Need"]).contains(need.id) }
            let implemented = serving.filter { !$0.isProposed }.map(\.id)
            let proposed = serving.filter(\.isProposed).map(\.id)
            lines.append("| \(need.id) | \(list(implemented)) | \(list(proposed)) |")
        }
        return lines.joined(separator: "\n")
    }

    /// A table of each hazard with its harms, controls, the requirements implementing them, and its residual risk.
    var hazardsToControls: String {
        let byID = documents.itemsByID
        var lines = ["| Hazard | Harms | Controls | Requirements | Residual |", "| --- | --- | --- | --- | --- |"]
        for hazard in documents.items(.hazard) {
            let controls = DesignDocuments.ids(in: hazard["Controls"]).filter { ItemKind(id: $0) == .control }
            var requirements: [String] = []
            var seen: Set<String> = []
            for control in controls.compactMap({ byID[$0] }) {
                for id in DesignDocuments.ids(in: control["Requirements"]) where seen.insert(id).inserted {
                    requirements.append(byID[id]?.isProposed == true ? "\(id) (proposed)" : id)
                }
            }
            let harms = DesignDocuments.ids(in: hazard["Harm"]).filter { ItemKind(id: $0) == .harm }
            let residual = hazard["Residual"].replacingOccurrences(of: "*", with: "")
            lines.append(
                "| \(hazard.id) | \(list(harms)) | \(list(controls)) | \(list(requirements)) | \(residual) |")
        }
        return lines.joined(separator: "\n")
    }

    /// A table counting requirements by how they're verified.
    var coverage: String {
        let requirements = documents.items(.requirement)
        var byCoverage: [Coverage: [String]] = [:]
        for requirement in requirements {
            let coverage = VerificationCell(requirement["Verified by"]).coverage(isProposed: requirement.isProposed)
            byCoverage[coverage, default: []].append(requirement.id.replacingOccurrences(of: "REQ-", with: ""))
        }
        var lines = ["| Coverage | Count | Requirements (REQ-…) |", "| --- | --- | --- |"]
        for coverage in Coverage.allCases {
            let ids = byCoverage[coverage] ?? []
            lines.append("| \(coverage.rawValue) | \(ids.count) | \(list(ids)) |")
        }
        let proposed = requirements.filter(\.isProposed).count
        lines.append("")
        lines.append(
            "\(requirements.count) requirements: \(requirements.count - proposed) implemented and \(proposed) proposed.")
        return lines.joined(separator: "\n")
    }

    /// A comma-separated list, or a dash for none.
    private func list(_ items: [String]) -> String { items.isEmpty ? "—" : items.joined(separator: ", ") }

    /// A one-line count of what was checked.
    var summary: String {
        let gaps = documents.items(.requirement).filter { VerificationCell($0["Verified by"]).gap }.count
        return [
            "\(documents.items(.need).count) needs", "\(documents.items(.requirement).count) requirements",
            "\(documents.items(.hazard).count) hazards", "\(documents.items(.control).count) controls",
            "\(tests.tests.count) tests", "\(documents.recordChecks.count) record checks",
            "\(gaps) requirements with a noted gap",
        ].joined(separator: ", ")
    }

    // MARK: - Splicing

    /// Returns a document with each generated section's body replaced by the current rendering.
    ///
    /// Sections whose markers are missing are left out; `staleSections()` reports them.
    ///
    /// - Parameter text: The document's Markdown.
    /// - Returns: The updated Markdown.
    func splice(into text: String) -> String {
        var text = text
        for section in sections {
            guard let range = bodyRange(of: section.name, in: text) else { continue }
            text.replaceSubrange(range, with: "\n" + section.body + "\n")
        }
        return text
    }

    /// Generated sections of traceability.md that are missing or don't match the current rendering.
    ///
    /// - Returns: One problem per such section.
    func staleSections() -> [Problem] {
        let location = Location(file: Self.traceabilityFile, line: 0)
        guard let text = documents.texts[Self.traceabilityFile] else {
            return [Problem(rule: .staleTraceability, location: location, message: "traceability.md is missing")]
        }
        return sections.compactMap { section in
            guard let range = bodyRange(of: section.name, in: text) else {
                return Problem(
                    rule: .staleTraceability, location: location,
                    message: "traceability.md has no generated section \"\(section.name)\"; add its trace markers")
            }
            guard text[range] != "\n" + section.body + "\n" else { return nil }
            let line = text[..<range.lowerBound].count(where: { $0 == "\n" }) + 1
            return Problem(
                rule: .staleTraceability, location: Location(file: Self.traceabilityFile, line: line),
                message: "the \"\(section.name)\" section is out of date; run `swift run maser-trace --write`")
        }
    }

    /// The text between a section's begin and end markers.
    ///
    /// - Parameters:
    ///   - name: The section's name.
    ///   - text: The document.
    /// - Returns: The range between the markers, or `nil` if either is missing or they're out of order.
    private func bodyRange(of name: String, in text: String) -> Range<String.Index>? {
        guard let begin = text.range(of: "<!-- trace:begin \(name) -->"),
            let end = text.range(of: "<!-- trace:end \(name) -->", range: begin.upperBound..<text.endIndex)
        else { return nil }
        return begin.upperBound..<end.lowerBound
    }
}
