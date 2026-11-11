// The traced items in `docs/design/`, and the verification records in `docs/verification/`.
//
// Each design document defines items in tables whose first column is `ID`: user needs, requirements, harms, hazards,
// risk controls and the usability file's items. This file loads them all, keeps where each was defined, and finds the
// IDs that any text mentions. It also lists the checks in each verification record, as `V-YYYY-MM-DD/Vn`.

import Foundation

/// The kinds of traced item, by ID prefix.
enum ItemKind: String, CaseIterable, Sendable {
    /// `UN-n`, in user-needs.md.
    case need = "UN"
    /// `REQ-AREA-nnn`, in requirements.md.
    case requirement = "REQ"
    /// `Hn`, in risk-management.md.
    case harm = "H"
    /// `HAZ-nn`, in risk-management.md.
    case hazard = "HAZ"
    /// `RC-nn`, in risk-management.md.
    case control = "RC"
    /// `UIC-n`, a user interface characteristic in usability.md.
    case uiCharacteristic = "UIC"
    /// `HRUS-n`, a hazard-related use scenario in usability.md.
    case useScenario = "HRUS"
    /// `FE-n`, a formative evaluation in usability.md.
    case formativeEvaluation = "FE"

    /// The kind of an ID, or `nil` if it isn't a traced item's ID.
    ///
    /// - Parameter id: A whole ID, such as `REQ-GH-001`.
    init?(id: String) {
        guard id.wholeMatch(of: #/UN-\d+|REQ-[A-Z]+-\d{3}|HAZ-\d{2}|RC-\d{2}|HRUS-\d+|UIC-\d+|FE-\d+|H\d+/#) != nil else {
            return nil
        }
        if id.hasPrefix("REQ-") {
            self = .requirement
        } else if id.hasPrefix("HAZ-") {
            self = .hazard
        } else if id.hasPrefix("HRUS-") {
            self = .useScenario
        } else if id.hasPrefix("UIC-") {
            self = .uiCharacteristic
        } else if id.hasPrefix("UN-") {
            self = .need
        } else if id.hasPrefix("RC-") {
            self = .control
        } else if id.hasPrefix("FE-") {
            self = .formativeEvaluation
        } else {
            self = .harm
        }
    }
}

/// One traced item: a row of a design document table whose first column is `ID`.
struct Item: Equatable, Sendable {
    /// The item's ID, such as `REQ-GH-001`.
    let id: String
    /// What kind of item it is, from its ID.
    let kind: ItemKind
    /// The row's cells by column heading.
    let fields: [String: String]
    /// The document it's defined in, relative to the repository root.
    let file: String
    /// The 1-based line of its row.
    let line: Int

    /// The cell under a heading, or an empty string if there's no such column.
    ///
    /// - Parameter heading: The column heading, exactly as written.
    subscript(heading: String) -> String { fields[heading] ?? "" }

    /// Whether the item's status says it's proposed rather than built.
    var isProposed: Bool { self["Status"].contains("Proposed") }
}

/// A place in a document, for reporting problems.
struct Location: Equatable, Hashable, Sendable, CustomStringConvertible {
    /// The file, relative to the repository root.
    let file: String
    /// The 1-based line, or 0 for the whole file.
    let line: Int

    var description: String { line > 0 ? "\(file):\(line)" : file }
}

/// All the design documents, parsed.
struct DesignDocuments: Sendable {
    /// Every item, in document order.
    let items: [Item]
    /// Each document's text, by path relative to the repository root.
    let texts: [String: String]
    /// The check IDs in the verification records, such as `V-2026-11-03/V10`.
    let recordChecks: Set<String>

    /// The directory holding the design documents, relative to the repository root.
    static let designDirectory = "docs/design"
    /// The directory holding the verification records, relative to the repository root.
    static let verificationDirectory = "docs/verification"

    /// Reads the design documents and verification records from a repository.
    ///
    /// - Parameter root: The repository's root directory.
    /// - Returns: The parsed documents.
    /// - Throws: A file system error if the design directory can't be read.
    static func load(root: URL) throws -> DesignDocuments {
        let fileManager = FileManager.default
        let designURL = root.appending(path: designDirectory)
        let names = try fileManager.contentsOfDirectory(atPath: designURL.path()).filter { $0.hasSuffix(".md") }.sorted()
        var texts: [String: String] = [:]
        for name in names {
            texts["\(designDirectory)/\(name)"] = try String(contentsOf: designURL.appending(path: name), encoding: .utf8)
        }

        var records: [String: String] = [:]
        let verificationURL = root.appending(path: verificationDirectory)
        let recordDirectories = (try? fileManager.contentsOfDirectory(atPath: verificationURL.path())) ?? []
        for directory in recordDirectories.sorted() {
            let readme = verificationURL.appending(path: directory).appending(path: "README.md")
            if let text = try? String(contentsOf: readme, encoding: .utf8) { records[directory] = text }
        }
        return DesignDocuments(texts: texts, records: records)
    }

    /// Parses documents already in memory.
    ///
    /// - Parameters:
    ///   - texts: Each design document's Markdown, by path.
    ///   - records: Each verification record's README, by directory name (which starts with its date).
    init(texts: [String: String], records: [String: String] = [:]) {
        self.texts = texts
        var items: [Item] = []
        for (file, text) in texts.sorted(by: { $0.key < $1.key }) {
            for table in MarkdownTable.tables(in: text) where table.headings.first == "ID" {
                for row in table.rows {
                    guard let id = row.values.first, let kind = ItemKind(id: id) else { continue }
                    items.append(Item(id: id, kind: kind, fields: row.cells, file: file, line: row.line))
                }
            }
        }
        self.items = items
        var checks: Set<String> = []
        for (directory, text) in records {
            let date = String(directory.prefix(10))
            guard date.wholeMatch(of: #/\d{4}-\d{2}-\d{2}/#) != nil else { continue }
            for line in text.split(separator: "\n") {
                if let match = line.prefixMatch(of: #/### (V\d+):/#) { checks.insert("V-\(date)/\(match.1)") }
            }
        }
        recordChecks = checks
    }

    /// The items of one kind, in document order.
    ///
    /// - Parameter kind: The kind to list.
    /// - Returns: The items.
    func items(_ kind: ItemKind) -> [Item] { items.filter { $0.kind == kind } }

    /// Every item by ID; for a duplicated ID, its first definition.
    var itemsByID: [String: Item] {
        Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The traced-item IDs mentioned in some text, in order of first mention.
    ///
    /// - Parameter text: Any text, such as a table cell.
    /// - Returns: The IDs, without repeats.
    static func ids(in text: String) -> [String] {
        var seen: Set<String> = []
        return text.matches(of: #/\b(?:UN-\d+|REQ-[A-Z]+-\d{3}|HAZ-\d{2}|RC-\d{2}|HRUS-\d+|UIC-\d+|FE-\d+|H\d+)\b/#)
            .map { String($0.output) }
            .filter { seen.insert($0).inserted }
    }

    /// The verification-record check IDs mentioned in some text, such as `V-2026-11-03/V10`.
    ///
    /// - Parameter text: Any text.
    /// - Returns: The check IDs, in order.
    static func recordCheckIDs(in text: String) -> [String] {
        text.matches(of: #/V-\d{4}-\d{2}-\d{2}\/V\d+/#).map { String($0.output) }
    }

    /// The issue numbers mentioned in some text, such as `#18`.
    ///
    /// - Parameter text: Any text.
    /// - Returns: The numbers, in order.
    static func issueNumbers(in text: String) -> [Int] {
        text.matches(of: #/#(\d+)\b/#).compactMap { Int($0.1) }
    }
}
