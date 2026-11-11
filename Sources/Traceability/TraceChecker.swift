// The traceability checks.
//
// `TraceChecker` holds the parsed design documents, verification records and test index, and reports every broken or
// missing link. Each check is described on its `Problem.Rule`, and docs/design/README.md describes the rules for
// people. A problem names the document and line to fix.

import Foundation

/// A broken or missing traceability link.
public struct Problem: Equatable, Sendable, CustomStringConvertible {
    /// The rule a problem breaks.
    public enum Rule: String, Sendable, CaseIterable {
        /// An ID is defined more than once.
        case duplicateID = "duplicate-id"
        /// A document or test mentions an ID that isn't defined.
        case unknownID = "unknown-id"
        /// A requirement names no user need.
        case requirementWithoutNeed = "requirement-without-need"
        /// A requirement's "Verified by" cell gives no reference, gap or plan.
        case unstatedVerification = "unstated-verification"
        /// A `T:` or `L:` reference names a suite or test that doesn't exist, or the wrong kind.
        case unknownTest = "unknown-test"
        /// A whole-suite reference claims `(all N)` but the suite has a different number of tests.
        case wrongTestCount = "wrong-test-count"
        /// A reference names a verification record check that doesn't exist.
        case unknownRecordCheck = "unknown-record-check"
        /// A proposed requirement has no issue.
        case proposedWithoutIssue = "proposed-without-issue"
        /// A requirement and a risk control disagree about whether the requirement implements the control.
        case controlLinkMismatch = "control-link-mismatch"
        /// A risk control's status disagrees with its requirements' statuses.
        case controlStatusMismatch = "control-status-mismatch"
        /// A risk control isn't used by any hazard.
        case unusedControl = "unused-control"
        /// A hazard has no harm or no control.
        case incompleteHazard = "incomplete-hazard"
        /// A user need has no implemented requirement.
        case unmetNeed = "unmet-need"
        /// A hazard whose residual risk is High, or marked open, isn't in the open risks table.
        case untrackedOpenRisk = "untracked-open-risk"
        /// A generated section of traceability.md is missing or out of date.
        case staleTraceability = "stale-traceability"
        /// A requirement cites a test whose name doesn't claim it, or a test claims a requirement that doesn't cite it.
        case testClaimMismatch = "test-claim-mismatch"
        /// A product test's name, or a UI scenario's title, claims no requirement.
        case untracedTest = "untraced-test"
        /// A `UI:` reference names a scenario that doesn't exist, or a planned one names a scenario that does.
        case unknownScenario = "unknown-scenario"
    }

    /// The rule broken.
    public let rule: Rule
    /// Where to fix it.
    let location: Location
    /// What's wrong, as a sentence.
    public let message: String

    /// The problem as `file:line: message [rule]`, for the console.
    public var description: String { "\(location): \(message) [\(rule.rawValue)]" }
}

/// Checks the links between needs, requirements, risks, controls, tests and verification records.
struct TraceChecker {
    /// The design documents and records.
    let documents: DesignDocuments
    /// The tests in the repository.
    let tests: TestIndex

    /// Runs every check except the generated-section check, which needs the rendered report.
    ///
    /// - Returns: The problems, in document order.
    func problems() -> [Problem] {
        var problems: [Problem] = []
        problems += duplicateIDs()
        problems += unknownIDs()
        problems += requirementProblems()
        problems += controlProblems()
        problems += hazardProblems()
        problems += unmetNeeds()
        problems += untrackedOpenRisks()
        problems += testClaimProblems()
        problems += scenarioProblems()
        return problems
    }

    /// The directory of tests that verify the traceability tool rather than Maser, which needn't claim requirements.
    static let toolTestDirectory = "Tests/TraceabilityTests/"

    /// The requirement IDs a test's display name claims, such as `["REQ-DIF-001"]` for `"REQ-DIF-001: …"`.
    ///
    /// - Parameter test: The test.
    /// - Returns: The requirement IDs in its display name, in order.
    static func claims(of test: TestCase) -> [String] {
        DesignDocuments.ids(in: test.displayName ?? "").filter { ItemKind(id: $0) == .requirement }
    }

    /// Mismatches between the tests requirements cite and the requirements tests claim, and untraced product tests.
    ///
    /// A whole-suite reference cites every test in the suite. Unknown suites and tests are left to
    /// `testReferenceProblems(_:for:)`.
    private func testClaimProblems() -> [Problem] {
        var problems: [Problem] = []
        // The tests each requirement cites, as "Suite.test".
        var cited: [String: Set<String>] = [:]
        for requirement in documents.items(.requirement) {
            for reference in VerificationCell(requirement["Verified by"]).tests {
                let suite = tests.tests(in: reference.suite)
                for test in suite where reference.test == nil || reference.test == test.name {
                    cited[requirement.id, default: []].insert("\(test.suite).\(test.name)")
                    if !Self.claims(of: test).contains(requirement.id) {
                        problems.append(
                            Problem(
                                rule: .testClaimMismatch, location: location(requirement),
                                message:
                                    "\(requirement.id) cites \(test.suite).\(test.name), but the test's name doesn't claim \(requirement.id) (\(test.location))"
                            ))
                    }
                }
            }
        }
        let requirementIDs = Set(documents.items(.requirement).map(\.id))
        for test in tests.tests {
            let claims = Self.claims(of: test)
            if claims.isEmpty && !test.location.file.hasPrefix(Self.toolTestDirectory) {
                problems.append(
                    Problem(
                        rule: .untracedTest, location: test.location,
                        message:
                            "\(test.suite).\(test.name) claims no requirement; name it @Test(\"REQ-…: …\") and cite it from the requirement"
                    ))
            }
            for id in claims where requirementIDs.contains(id) && cited[id]?.contains("\(test.suite).\(test.name)") != true {
                problems.append(
                    Problem(
                        rule: .testClaimMismatch, location: test.location,
                        message: "\(test.suite).\(test.name) claims \(id), but \(id) doesn't cite it"))
            }
        }
        return problems
    }

    /// Scenario references that don't match the scenarios, and mismatched or missing scenario claims.
    ///
    /// Scenarios follow the same two-way rule as tests: a requirement that cites `UI:name` must be claimed in the
    /// scenario's title, and a scenario must claim at least one requirement, each of which cites it.
    private func scenarioProblems() -> [Problem] {
        var problems: [Problem] = []
        let byName = Dictionary(tests.scenarios.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var cited: [String: Set<String>] = [:]
        for requirement in documents.items(.requirement) {
            let cell = VerificationCell(requirement["Verified by"])
            for name in cell.scenarios {
                guard let scenario = byName[name] else {
                    problems.append(
                        Problem(
                            rule: .unknownScenario, location: location(requirement),
                            message: "\(requirement.id) cites UI:\(name), but \(TestIndex.scenarioFile) has no such scenario"))
                    continue
                }
                cited[requirement.id, default: []].insert(name)
                if !DesignDocuments.ids(in: scenario.title).contains(requirement.id) {
                    problems.append(
                        Problem(
                            rule: .testClaimMismatch, location: location(requirement),
                            message:
                                "\(requirement.id) cites UI:\(name), but the scenario's title doesn't claim \(requirement.id) (\(scenario.location))"
                        ))
                }
            }
            for name in cell.plannedScenarios where byName[name] != nil {
                problems.append(
                    Problem(
                        rule: .unknownScenario, location: location(requirement),
                        message: "\(requirement.id) lists UI:\(name) as a gap, but the scenario exists; cite it before the Gap"))
            }
        }
        let requirementIDs = Set(documents.items(.requirement).map(\.id))
        for scenario in tests.scenarios {
            let claims = DesignDocuments.ids(in: scenario.title).filter { ItemKind(id: $0) == .requirement }
            if claims.isEmpty {
                problems.append(
                    Problem(
                        rule: .untracedTest, location: scenario.location,
                        message: "UI scenario \(scenario.name) claims no requirement; start its title with \"REQ-…: \""))
            }
            for id in claims where requirementIDs.contains(id) && cited[id]?.contains(scenario.name) != true {
                problems.append(
                    Problem(
                        rule: .testClaimMismatch, location: scenario.location,
                        message: "UI scenario \(scenario.name) claims \(id), but \(id) doesn't cite UI:\(scenario.name)"))
            }
        }
        return problems
    }

    /// The location of an item's row.
    private func location(_ item: Item) -> Location { Location(file: item.file, line: item.line) }

    /// IDs defined more than once.
    private func duplicateIDs() -> [Problem] {
        var first: [String: Item] = [:]
        var problems: [Problem] = []
        for item in documents.items {
            if let original = first[item.id] {
                problems.append(
                    Problem(
                        rule: .duplicateID, location: location(item),
                        message: "\(item.id) is already defined at \(location(original))"))
            } else {
                first[item.id] = item
            }
        }
        return problems
    }

    /// IDs mentioned in the design documents (other than README.md's examples) or in test names that aren't defined.
    private func unknownIDs() -> [Problem] {
        let defined = Set(documents.items.map(\.id))
        var problems: [Problem] = []
        for (file, text) in documents.texts.sorted(by: { $0.key < $1.key }) where !file.hasSuffix("/README.md") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, line) in lines.enumerated() {
                for id in DesignDocuments.ids(in: String(line)) where !defined.contains(id) {
                    problems.append(
                        Problem(
                            rule: .unknownID, location: Location(file: file, line: offset + 1),
                            message: "\(id) isn't defined in any design document"))
                }
            }
        }
        for scenario in tests.scenarios {
            for id in DesignDocuments.ids(in: scenario.title) where !defined.contains(id) {
                problems.append(
                    Problem(
                        rule: .unknownID, location: scenario.location,
                        message: "UI scenario \(scenario.name) cites \(id), which isn't defined"))
            }
        }
        for test in tests.tests {
            for id in DesignDocuments.ids(in: test.displayName ?? "") where !defined.contains(id) {
                problems.append(
                    Problem(
                        rule: .unknownID, location: test.location,
                        message: "test \(test.suite).\(test.name) cites \(id), which isn't defined"))
            }
        }
        return problems
    }

    /// Each requirement's need, verification, tests, record checks, issue and control links.
    private func requirementProblems() -> [Problem] {
        let byID = documents.itemsByID
        var problems: [Problem] = []
        for requirement in documents.items(.requirement) {
            let here = location(requirement)
            if !DesignDocuments.ids(in: requirement["Need"]).contains(where: { ItemKind(id: $0) == .need }) {
                problems.append(
                    Problem(rule: .requirementWithoutNeed, location: here, message: "\(requirement.id) names no user need"))
            }

            let cell = VerificationCell(requirement["Verified by"])
            if cell.isEmpty {
                problems.append(
                    Problem(
                        rule: .unstatedVerification, location: here,
                        message:
                            "\(requirement.id) says nothing about verification; cite a test, record, inspection or use, or note the Gap"
                    ))
            }
            problems += testReferenceProblems(cell.tests, for: requirement)
            for check in cell.recordChecks where !documents.recordChecks.contains(check) {
                problems.append(
                    Problem(
                        rule: .unknownRecordCheck, location: here,
                        message: "\(requirement.id) cites \(check), which no verification record has"))
            }

            if requirement.isProposed && DesignDocuments.issueNumbers(in: requirement["Status"]).isEmpty {
                problems.append(
                    Problem(
                        rule: .proposedWithoutIssue, location: here,
                        message: "\(requirement.id) is Proposed but its status names no issue, such as (#18)"))
            }

            for controlID in DesignDocuments.ids(in: requirement["Control"]) {
                guard let control = byID[controlID], control.kind == .control else { continue }
                if !DesignDocuments.ids(in: control["Requirements"]).contains(requirement.id) {
                    problems.append(
                        Problem(
                            rule: .controlLinkMismatch, location: here,
                            message:
                                "\(requirement.id) implements \(controlID), but \(controlID) doesn't list it (\(location(control)))"
                        ))
                }
            }
        }
        return problems
    }

    /// Problems with the test references of one requirement.
    ///
    /// - Parameters:
    ///   - references: The requirement's test references.
    ///   - requirement: The requirement, for messages and location.
    /// - Returns: A problem for each reference to a missing suite or test, a live test cited as offline or the
    ///   reverse, or a wrong `(all N)` count.
    private func testReferenceProblems(_ references: [TestReference], for requirement: Item) -> [Problem] {
        var problems: [Problem] = []
        for reference in references {
            let suite = tests.tests(in: reference.suite)
            let problem = { (rule: Problem.Rule, message: String) in
                problems.append(Problem(rule: rule, location: location(requirement), message: message))
            }
            guard !suite.isEmpty else {
                problem(.unknownTest, "\(requirement.id) cites \(reference.text), but there's no suite \(reference.suite)")
                continue
            }
            let cited = reference.test.map { name in suite.filter { $0.name == name } } ?? suite
            guard let test = cited.first else {
                problem(.unknownTest, "\(requirement.id) cites \(reference.text), but \(reference.suite) has no such test")
                continue
            }
            if test.isLive != reference.isLive {
                let kind = test.isLive ? "a live test; cite it as L:" : "an offline test; cite it as T:"
                problem(.unknownTest, "\(requirement.id) cites \(reference.text), which is \(kind)")
            }
            if let claimed = reference.claimedCount, claimed != suite.count {
                problem(
                    .wrongTestCount,
                    "\(requirement.id) says \(reference.suite) has \(claimed) tests (all \(claimed)), but it has \(suite.count)")
            }
        }
        return problems
    }

    /// Each control's requirement links and status, and whether any hazard uses it.
    private func controlProblems() -> [Problem] {
        let byID = documents.itemsByID
        let usedByHazards = Set(documents.items(.hazard).flatMap { DesignDocuments.ids(in: $0["Controls"]) })
        var problems: [Problem] = []
        for control in documents.items(.control) {
            let here = location(control)
            let requirements = DesignDocuments.ids(in: control["Requirements"]).compactMap { byID[$0] }
                .filter { $0.kind == .requirement }
            for requirement in requirements where !DesignDocuments.ids(in: requirement["Control"]).contains(control.id) {
                problems.append(
                    Problem(
                        rule: .controlLinkMismatch, location: here,
                        message:
                            "\(control.id) lists \(requirement.id), but \(requirement.id)'s Control column doesn't name it (\(location(requirement)))"
                    ))
            }
            let anyProposed = requirements.contains(where: \.isProposed)
            if control.isProposed != anyProposed, !requirements.isEmpty {
                let message =
                    control.isProposed
                    ? "\(control.id) is Proposed, but all its requirements are implemented"
                    : "\(control.id) isn't marked Proposed, but \(requirements.filter(\.isProposed).map(\.id).joined(separator: ", ")) is"
                problems.append(Problem(rule: .controlStatusMismatch, location: here, message: message))
            }
            if !usedByHazards.contains(control.id) {
                problems.append(Problem(rule: .unusedControl, location: here, message: "no hazard uses \(control.id)"))
            }
        }
        return problems
    }

    /// Hazards without a harm or a control.
    private func hazardProblems() -> [Problem] {
        documents.items(.hazard).compactMap { hazard in
            let harms = DesignDocuments.ids(in: hazard["Harm"]).filter { ItemKind(id: $0) == .harm }
            let controls = DesignDocuments.ids(in: hazard["Controls"]).filter { ItemKind(id: $0) == .control }
            guard harms.isEmpty || controls.isEmpty else { return nil }
            return Problem(
                rule: .incompleteHazard, location: location(hazard),
                message: "\(hazard.id) needs at least one harm (Hn) and one control (RC-nn)")
        }
    }

    /// User needs that no implemented requirement serves.
    private func unmetNeeds() -> [Problem] {
        let implemented = documents.items(.requirement).filter { !$0.isProposed }
        return documents.items(.need).compactMap { need in
            guard !implemented.contains(where: { DesignDocuments.ids(in: $0["Need"]).contains(need.id) }) else { return nil }
            return Problem(rule: .unmetNeed, location: location(need), message: "no implemented requirement serves \(need.id)")
        }
    }

    /// Hazards whose residual risk is High, or marked open, that the open risks table doesn't list.
    private func untrackedOpenRisks() -> [Problem] {
        let tracked = Set(
            documents.texts.values.flatMap { text in
                MarkdownTable.tables(in: text).filter { $0.headings.first == "Hazard" && $0.headings.contains("Issue") }
                    .flatMap { $0.rows.flatMap { DesignDocuments.ids(in: $0["Hazard"]) } }
            })
        return documents.items(.hazard).compactMap { hazard in
            let residual = hazard["Residual"]
            guard residual.contains("High") || residual.contains("open"), !tracked.contains(hazard.id) else { return nil }
            return Problem(
                rule: .untrackedOpenRisk, location: location(hazard),
                message: "\(hazard.id)'s residual risk is \(residual), but the open risks table doesn't list it with an issue")
        }
    }
}
