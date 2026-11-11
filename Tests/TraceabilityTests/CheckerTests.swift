// Tests for the traceability rules and the generated sections of traceability.md.
//
// Each test starts from a small, fully consistent set of documents and tests, breaks one link, and checks that exactly
// the expected rule fires.

import Foundation
import Testing

@testable import Traceability

/// A small, consistent design: one need, three requirements (one proposed), two hazards, two controls, two tests.
struct Fixture {
    var needs = """
        | ID | Need | Why |
        | --- | --- | --- |
        | UN-1 | A need | Because |
        """
    var requirements = """
        | ID | Requirement | Need | Control | Verified by | Status |
        | --- | --- | --- | --- | --- | --- |
        | REQ-AB-001 | First | UN-1 | RC-01 | T:SuiteA.one, .two | Implemented |
        | REQ-AB-002 | Second | UN-1 | — | V-2026-11-03/V1. **Gap:** UI:second. | Implemented |
        | REQ-AB-003 | Third | UN-1 | RC-02 | Planned: T for the store. | **Proposed** (#5) |
        """
    var risks = """
        | ID | Harm | Severity |
        | --- | --- | --- |
        | H1 | A harm | S2 Minor |

        | ID | Hazard and sequence of events | Harm | Initial | Controls | Residual |
        | --- | --- | --- | --- | --- | --- |
        | HAZ-01 | Something goes wrong | H1 | S2 P3 Medium | RC-01 | S2 P1 Low |
        | HAZ-02 | Something else | H1 | S2 P4 Medium | RC-02 (*proposed*) | S2 P3 Medium: open |

        | ID | Control | Type | Requirements | Status |
        | --- | --- | --- | --- | --- |
        | RC-01 | A control | Protective measure | REQ-AB-001 | Implemented |
        | RC-02 | Another | Protective measure | REQ-AB-003 | **Proposed** |

        | Hazard | Residual | Needs | Issue |
        | --- | --- | --- | --- |
        | HAZ-02 | Medium | RC-02 | #5 |
        """
    var tests = """
        @Suite struct SuiteA {
            @Test("REQ-AB-001: One") func one() {}
            @Test("REQ-AB-001: Two") func two() {}
        }
        """
    /// The UI scenario file's source, if any.
    var scenarios: String?
    var record = "### V1: A check"
    /// Replaces traceability.md as given; `nil` generates it, so it's up to date.
    var traceability: String?

    /// The documents, with traceability.md generated unless `traceability` is set.
    var documents: DesignDocuments {
        var texts = [
            "docs/design/user-needs.md": needs, "docs/design/requirements.md": requirements,
            "docs/design/risk-management.md": risks,
        ]
        let records = ["2026-11-03-checks": record]
        let markers = ["needs-to-requirements", "hazards-to-controls", "coverage"]
            .map { "<!-- trace:begin \($0) -->\n<!-- trace:end \($0) -->" }.joined(separator: "\n\n")
        texts["docs/design/traceability.md"] = markers
        let draft = TraceReport(documents: DesignDocuments(texts: texts, records: records), tests: index)
        texts["docs/design/traceability.md"] = traceability ?? draft.splice(into: markers)
        return DesignDocuments(texts: texts, records: records)
    }

    /// The tests.
    var index: TestIndex { TestIndex(sources: ["Tests/X/SuiteA.swift": tests], scenarioSource: scenarios) }

    /// The rules broken, in order.
    var rules: [Problem.Rule] {
        let report = TraceReport(documents: documents, tests: index)
        return (TraceChecker(documents: documents, tests: index).problems() + report.staleSections()).map(\.rule)
    }
}

/// Tests for `TraceChecker` and `TraceReport`.
@Suite struct TraceCheckerTests {
    @Test func consistentDesignHasNoProblems() {
        #expect(Fixture().rules == [])
    }

    @Test func duplicateID() {
        var fixture = Fixture()
        fixture.needs += "\n| UN-1 | Again | Oops |"
        #expect(fixture.rules == [.duplicateID])
    }

    @Test func unknownIDInDocumentsAndTestNames() {
        var fixture = Fixture()
        fixture.risks = fixture.risks.replacingOccurrences(of: "| A harm |", with: "| A harm, see HAZ-09 |")
        fixture.tests = fixture.tests.replacingOccurrences(of: "REQ-AB-001: Two", with: "REQ-AB-001, REQ-ZZ-001: Two")
        #expect(fixture.rules == [.unknownID, .unknownID])
    }

    @Test func requirementWithoutNeed() {
        var fixture = Fixture()
        fixture.requirements = fixture.requirements.replacingOccurrences(of: "| Second | UN-1 |", with: "| Second | — |")
        #expect(fixture.rules == [.requirementWithoutNeed])
    }

    @Test func unstatedVerification() {
        var fixture = Fixture()
        fixture.requirements = fixture.requirements.replacingOccurrences(
            of: "V-2026-11-03/V1. **Gap:** UI:second.", with: "Checked once.")
        #expect(fixture.rules == [.unstatedVerification])
    }

    /// A missing suite, a missing test, and a live test cited as offline are each `unknown-test`.
    @Test func unknownTests() {
        var fixture = Fixture()
        fixture.requirements = fixture.requirements.replacingOccurrences(
            of: "T:SuiteA.one, .two", with: "T:SuiteA.one, .three; T:Nowhere; L:SuiteA.one")
        // SuiteA.two is no longer cited but still claims REQ-AB-001, so the claim check reports it too.
        #expect(fixture.rules == [.unknownTest, .unknownTest, .unknownTest, .testClaimMismatch])
    }

    @Test func wrongTestCount() {
        var fixture = Fixture()
        fixture.requirements = fixture.requirements.replacingOccurrences(of: "T:SuiteA.one, .two", with: "T:SuiteA (all 3)")
        #expect(fixture.rules == [.wrongTestCount])
    }

    @Test func unknownRecordCheck() {
        var fixture = Fixture()
        fixture.record = "### V2: A different check"
        #expect(fixture.rules == [.unknownRecordCheck])
    }

    @Test func proposedWithoutIssue() {
        var fixture = Fixture()
        fixture.requirements = fixture.requirements.replacingOccurrences(of: "**Proposed** (#5)", with: "**Proposed**")
        #expect(fixture.rules == [.proposedWithoutIssue])
    }

    /// A requirement naming a control that doesn't list it, and a control listing a requirement that doesn't name it.
    @Test func controlLinkMismatchBothWays() {
        var fixture = Fixture()
        fixture.requirements = fixture.requirements.replacingOccurrences(
            of: "| Second | UN-1 | — |", with: "| Second | UN-1 | RC-01 |")
        #expect(fixture.rules == [.controlLinkMismatch])
        fixture = Fixture()
        fixture.risks = fixture.risks.replacingOccurrences(
            of: "| REQ-AB-001 | Implemented |", with: "| REQ-AB-001, REQ-AB-002 | Implemented |")
        #expect(fixture.rules == [.controlLinkMismatch])
    }

    /// A requirement citing a test whose name doesn't claim it, and a test claiming a requirement that doesn't cite it.
    @Test func testClaimMismatchBothWays() {
        var fixture = Fixture()
        fixture.tests = fixture.tests.replacingOccurrences(of: "REQ-AB-001: Two", with: "REQ-AB-002: Two")
        #expect(fixture.rules == [.testClaimMismatch, .testClaimMismatch])
    }

    /// A whole-suite reference cites every test in the suite, so each must claim the requirement.
    @Test func suiteReferenceCitesEveryTest() {
        var fixture = Fixture()
        fixture.requirements = fixture.requirements.replacingOccurrences(of: "T:SuiteA.one, .two", with: "T:SuiteA (all 2)")
        #expect(fixture.rules == [])
        fixture.tests = fixture.tests.replacingOccurrences(
            of: "}\n}", with: "}\n    @Test(\"REQ-AB-002: Three\") func three() {}\n}")
        fixture.requirements = fixture.requirements.replacingOccurrences(of: "(all 2)", with: "(all 3)")
        #expect(fixture.rules == [.testClaimMismatch, .testClaimMismatch])
    }

    /// UI scenarios follow the same two-way rule as tests, and a gap mustn't list a scenario that exists.
    @Test func scenarioRules() {
        var fixture = Fixture()
        fixture.scenarios = """
            static let second = UIScenario(
                "second", "REQ-AB-002: Second"
            ) { app in }
            """
        // REQ-AB-002 still lists it as a gap, so it doesn't cite it.
        #expect(fixture.rules == [.unknownScenario, .testClaimMismatch])

        fixture.requirements = fixture.requirements.replacingOccurrences(
            of: "V-2026-11-03/V1. **Gap:** UI:second.", with: "UI:second; V-2026-11-03/V1.")
        fixture.traceability = nil
        #expect(fixture.rules == [])

        fixture.scenarios = fixture.scenarios?.replacingOccurrences(of: "REQ-AB-002: Second", with: "Second")
        #expect(fixture.rules == [.testClaimMismatch, .untracedTest])

        fixture.scenarios = nil
        #expect(fixture.rules.first == .unknownScenario)
    }

    /// A product test must claim a requirement; the traceability tool's own tests needn't.
    @Test func untracedTest() {
        var fixture = Fixture()
        fixture.tests = fixture.tests.replacingOccurrences(of: "}\n}", with: "}\n    @Test func helper() {}\n}")
        #expect(fixture.rules == [.untracedTest])
        let toolTests = TestIndex(sources: ["Tests/TraceabilityTests/X.swift": "@Suite struct T {\n    @Test func a() {}\n}"])
        let problems = TraceChecker(documents: fixture.documents, tests: toolTests).problems()
        #expect(!problems.map(\.rule).contains(.untracedTest))
    }

    @Test func controlStatusMismatch() {
        var fixture = Fixture()
        fixture.risks = fixture.risks.replacingOccurrences(
            of: "| REQ-AB-003 | **Proposed** |", with: "| REQ-AB-003 | Implemented |")
        #expect(fixture.rules == [.controlStatusMismatch])
    }

    @Test func unusedControl() {
        var fixture = Fixture()
        fixture.risks = fixture.risks.replacingOccurrences(
            of: "| RC-02 | Another | Protective measure | REQ-AB-003 | **Proposed** |",
            with:
                "| RC-02 | Another | Protective measure | REQ-AB-003 | **Proposed** |\n| RC-03 | Unused | Protective measure | — | Implemented |"
        )
        #expect(fixture.rules == [.unusedControl])
    }

    @Test func incompleteHazard() {
        var fixture = Fixture()
        fixture.risks = fixture.risks.replacingOccurrences(of: "| H1 | S2 P3 Medium | RC-01 |", with: "| H1 | S2 P3 Medium | — |")
        #expect(fixture.rules == [.unusedControl, .incompleteHazard])
    }

    @Test func unmetNeed() {
        var fixture = Fixture()
        fixture.needs += "\n| UN-2 | Unserved | Nobody |"
        #expect(fixture.rules == [.unmetNeed])
    }

    @Test func untrackedOpenRisk() {
        var fixture = Fixture()
        fixture.risks = fixture.risks.replacingOccurrences(of: "| HAZ-02 | Medium | RC-02 | #5 |", with: "")
        #expect(fixture.rules == [.untrackedOpenRisk])
    }

    /// A generated section that's been edited, or whose markers are gone, is reported; splicing brings it up to date.
    @Test func staleAndMissingSections() throws {
        let current = try #require(Fixture().documents.texts["docs/design/traceability.md"])
        var fixture = Fixture()
        fixture.traceability = current.replacingOccurrences(of: "| UN-1 |", with: "| UN-1 (edited) |")
        #expect(fixture.rules == [.staleTraceability])
        let report = TraceReport(documents: fixture.documents, tests: fixture.index)
        #expect(report.splice(into: try #require(fixture.traceability)) == current)

        fixture.traceability = current.replacingOccurrences(of: "<!-- trace:end coverage -->", with: "")
        #expect(fixture.rules == [.staleTraceability])
    }

    /// The generated tables list what serves each need, what implements each hazard's controls, and the coverage.
    @Test func generatedTables() {
        let report = TraceReport(documents: Fixture().documents, tests: Fixture().index)
        #expect(report.needsToRequirements.contains("| UN-1 | REQ-AB-001, REQ-AB-002 | REQ-AB-003 |"))
        #expect(report.hazardsToControls.contains("| HAZ-02 | H1 | RC-02 | REQ-AB-003 (proposed) | S2 P3 Medium: open |"))
        #expect(report.coverage.contains("| Unit tests, fully | 1 | AB-001 |"))
        #expect(report.coverage.contains("| A one-off scripted run or use (not repeatable) | 1 | AB-002 |"))
        #expect(report.coverage.contains("3 requirements: 2 implemented and 1 proposed."))
    }
}
