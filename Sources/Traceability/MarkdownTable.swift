// Reading the tables out of a Markdown document.
//
// The design documents keep every traced item (needs, requirements, hazards, controls) in GitHub-style pipe tables.
// This file finds those tables and splits their rows into cells keyed by column heading, remembering each row's line
// number so problems can point at it.

import Foundation

/// A pipe table from a Markdown document.
struct MarkdownTable: Equatable {
    /// One body row of a table.
    struct Row: Equatable {
        /// The row's cells by column heading, trimmed.
        let cells: [String: String]
        /// The row's cells in column order, trimmed.
        let values: [String]
        /// The 1-based line number of the row in its document.
        let line: Int

        /// The cell under a heading, or an empty string if the table has no such column.
        ///
        /// - Parameter heading: The column heading, exactly as written.
        subscript(heading: String) -> String { cells[heading] ?? "" }
    }

    /// The column headings, trimmed, in order.
    let headings: [String]
    /// The body rows, in order.
    let rows: [Row]

    /// Finds every pipe table in a document.
    ///
    /// A table is a row of headings, then a separator row of dashes (`| --- |`), then body rows, up to the first line
    /// that doesn't start with `|`.
    ///
    /// - Parameter text: The document's Markdown.
    /// - Returns: The tables, in document order.
    static func tables(in text: String) -> [MarkdownTable] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var tables: [MarkdownTable] = []
        var index = 0
        while index + 1 < lines.count {
            guard isTableLine(lines[index]), isSeparator(lines[index + 1]) else {
                index += 1
                continue
            }
            let headings = cells(of: lines[index])
            var rows: [Row] = []
            index += 2
            while index < lines.count, isTableLine(lines[index]) {
                let values = cells(of: lines[index])
                var byHeading: [String: String] = [:]
                for (heading, value) in zip(headings, values) where byHeading[heading] == nil {
                    byHeading[heading] = value
                }
                rows.append(Row(cells: byHeading, values: values, line: index + 1))
                index += 1
            }
            tables.append(MarkdownTable(headings: headings, rows: rows))
        }
        return tables
    }

    /// Whether a line is part of a pipe table.
    private static func isTableLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    /// Whether a line is a table's separator row, such as `| --- | :--: |`.
    private static func isSeparator(_ line: String) -> Bool {
        let values = cells(of: line)
        return !values.isEmpty && values.allSatisfy { cell in !cell.isEmpty && cell.allSatisfy { "-: ".contains($0) } }
    }

    /// Splits a table line into trimmed cells.
    ///
    /// Pipes inside backticks and escaped pipes (`\|`) don't split cells.
    ///
    /// - Parameter line: A line starting with `|`.
    /// - Returns: The cells, without the outer pipes.
    static func cells(of line: String) -> [String] {
        var trimmed = Substring(line.trimmingCharacters(in: .whitespaces))
        if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed = trimmed.dropLast() }
        var cells: [String] = []
        var cell = ""
        var inCode = false
        var previous: Character?
        for character in trimmed {
            if character == "`" { inCode.toggle() }
            if character == "|" && !inCode && previous != "\\" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
            previous = character
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }
}
