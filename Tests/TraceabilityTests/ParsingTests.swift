// Tests for reading the design documents: Markdown tables, item IDs, verification cells, records and the test index.

import Foundation
import Testing

@testable import Traceability

/// Tests for `MarkdownTable`.
@Suite struct MarkdownTableTests {
    /// Reads headings and rows with their line numbers, and stops at the first line that isn't part of the table.
    @Test func readsTablesWithLineNumbers() throws {
        let text = """
            # Title

            | ID | Name |
            | --- | :--: |
            | A-1 | first |
            | A-2 | second |
            Not a table.
            | not | a table either |
            """
        let tables = MarkdownTable.tables(in: text)
        #expect(tables.count == 1)
        let table = try #require(tables.first)
        #expect(table.headings == ["ID", "Name"])
        #expect(table.rows.map(\.line) == [5, 6])
        #expect(table.rows[1]["Name"] == "second")
        #expect(table.rows[1]["Missing"] == "")
    }

    /// Doesn't split cells on pipes inside backticks or escaped pipes.
    @Test func keepsPipesInCodeAndEscapes() {
        #expect(MarkdownTable.cells(of: "| a | `x | y` | b \\| c |") == ["a", "`x | y`", "b \\| c"])
    }
}

/// Tests for item IDs and `DesignDocuments`.
@Suite struct DesignDocumentsTests {
    /// Tells each kind of ID apart, and rejects text that isn't a whole ID.
    @Test func itemKinds() {
        #expect(ItemKind(id: "UN-3") == .need)
        #expect(ItemKind(id: "REQ-GH-001") == .requirement)
        #expect(ItemKind(id: "H2") == .harm)
        #expect(ItemKind(id: "HAZ-02") == .hazard)
        #expect(ItemKind(id: "RC-12") == .control)
        #expect(ItemKind(id: "HRUS-1") == .useScenario)
        #expect(ItemKind(id: "UIC-4") == .uiCharacteristic)
        #expect(ItemKind(id: "FE-6") == .formativeEvaluation)
        #expect(ItemKind(id: "REQ-GH-1") == nil)
        #expect(ItemKind(id: "Need") == nil)
    }

    /// Finds whole IDs in prose, once each, and not inside other words.
    @Test func idsInText() {
        let text = "RC-04 (*proposed*) and RC-17; REQ-CMT-007 implements RC-04. SHA1 isn't H1, but H1 is."
        #expect(DesignDocuments.ids(in: text) == ["RC-04", "RC-17", "REQ-CMT-007", "H1"])
        #expect(DesignDocuments.recordCheckIDs(in: "See V-2026-11-03/V10 and V5.") == ["V-2026-11-03/V10"])
        #expect(DesignDocuments.issueNumbers(in: "**Proposed** (#18), see #20") == [18, 20])
    }

    /// Defines items only from tables whose first column is `ID`, and lists record checks by their record's date.
    @Test func loadsItemsAndRecordChecks() {
        let documents = DesignDocuments(
            texts: [
                "docs/design/a.md": """
                | ID | Need |
                | --- | --- |
                | UN-1 | Something |
                | UN-x | Not an ID |

                | Hazard | Residual |
                | --- | --- |
                | HAZ-01 | Low |
                """
            ],
            records: [
                "2026-11-03-ui-checks": "## Details\n\n### V1: First\n\n### V2: Second\n#### V3: not a check",
                "notes": "### V1: no date in the directory name",
            ])
        #expect(documents.items.map(\.id) == ["UN-1"])
        #expect(documents.items.first?.line == 3)
        #expect(documents.items.first?["Need"] == "Something")
        #expect(documents.recordChecks == ["V-2026-11-03/V1", "V-2026-11-03/V2"])
    }
}

/// Tests for `VerificationCell`.
@Suite struct VerificationCellTests {
    /// Reads test references, including `, .test` continuations, `(all N)`, and both kinds.
    @Test func readsTestReferences() {
        let cell = VerificationCell("T:Overview.decodes, .quoting; T:Parser (all 7); L:LiveTests.pages")
        #expect(cell.tests.map(\.text) == ["T:Overview.decodes", "T:Overview.quoting", "T:Parser", "L:LiveTests.pages"])
        #expect(cell.tests[2].claimedCount == 7)
        #expect(cell.tests[3].isLive)
    }

    /// Counts `I:` and `U:` only at the start of a word, so `UI:scenario` isn't an inspection.
    @Test func prefixesStartWords() {
        let planned = VerificationCell("**Gap:** UI:queue-cache.")
        #expect(!planned.inspection && !planned.use && planned.gap && planned.tests.isEmpty)
        #expect(VerificationCell("I: the code").inspection)
        #expect(VerificationCell("U: the user, PR #13").use)
        #expect(VerificationCell("Measured once, by hand.").isEmpty)
    }

    /// Classifies coverage by the strongest verification cited.
    @Test func classifiesCoverage() {
        #expect(VerificationCell("T:A.b").coverage(isProposed: false) == .unitTests)
        #expect(VerificationCell("T:A.b. **Gap:** more").coverage(isProposed: false) == .unitTestsPartly)
        #expect(VerificationCell("L:Live.b").coverage(isProposed: false) == .liveTestsOnly)
        #expect(VerificationCell("V-2026-11-03/V10").coverage(isProposed: false) == .recordOnly)
        #expect(VerificationCell("I: code").coverage(isProposed: false) == .inspectionOnly)
        #expect(VerificationCell("**Gap:** nothing").coverage(isProposed: false) == .none)
        #expect(VerificationCell("T:A.b").coverage(isProposed: true) == .proposed)
    }
}

/// Tests for `TestIndex`.
@Suite struct TestIndexTests {
    /// Skips test code inside multi-line string literals, such as fixtures like the one above.
    @Test func skipsStringLiterals() {
        let index = TestIndex(sources: [
            "Tests/X/FixtureTests.swift": #"""
            @Suite struct Real {
                static let fixture = """
                    @Test func fake() {}
                    """
                @Test func real() {}
            }
            """#
        ])
        #expect(index.tests.map { "\($0.suite).\($0.name)" } == ["Real.real"])
    }

    /// Finds tests in suites and free functions, live suites, display names, and `@Test` on its own line.
    @Test func findsTests() {
        let index = TestIndex(sources: [
            "Tests/X/ParserTests.swift": """
            @Test func freeTest() {}

            /// Docs.
            @Suite struct Parser {
                static func helper() {}
                @Test("REQ-AB-001: parses") func parses() {}
                @Test(.tags(.slow))
                func slow() {}
            }

            @Suite(.enabled(if: ProcessInfo.processInfo.environment["MASER_LIVE_TESTS"] != nil))
            struct LiveParser {
                @Test func remote() async throws {}
            }
            """
        ])
        #expect(
            index.tests.map { "\($0.suite).\($0.name)" } == [
                "ParserTests.freeTest", "Parser.parses", "Parser.slow", "LiveParser.remote",
            ])
        #expect(index.tests.map(\.isLive) == [false, false, false, true])
        #expect(index.tests[1].displayName == "REQ-AB-001: parses")
        #expect(index.tests[2].location.line == 7)
    }
}
