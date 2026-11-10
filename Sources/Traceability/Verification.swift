// What a requirement's "Verified by" cell says, and the tests it can point at.
//
// A cell mixes references such as `T:Suite.test`, `L:Suite`, `UI:scenario`, `V-2026-11-03/V10`, `I:` and `U:` with
// prose and an explicit `Gap`. `VerificationCell` pulls out the references and classifies the requirement's coverage.
// `TestIndex` lists every Swift Testing test and UI scenario in the repository, so references can be checked against
// them.

import Foundation

/// A reference to tests: `T:` for offline unit tests, `L:` for live tests against GitHub.
struct TestReference: Equatable, Sendable {
    /// Whether the reference is to live tests (`L:`) rather than offline ones (`T:`).
    let isLive: Bool
    /// The suite: a `@Suite` type's name, or the file name for tests outside a type.
    let suite: String
    /// One test in the suite, or `nil` for the whole suite.
    let test: String?
    /// The number of tests claimed by `(all N)` after a whole-suite reference.
    let claimedCount: Int?

    /// The reference as written, such as `T:Suite.test`.
    var text: String { "\(isLive ? "L" : "T"):\(suite)" + (test.map { ".\($0)" } ?? "") }
}

/// How well a requirement is verified, from its "Verified by" cell and status.
enum Coverage: String, CaseIterable, Sendable {
    /// Offline unit tests, with no gap noted.
    case unitTests = "Unit tests, fully"
    /// Offline unit tests, with a gap noted.
    case unitTestsPartly = "Unit tests, partly (the rest is a gap)"
    /// Scripted UI scenarios, but no offline unit tests.
    case uiScenarios = "UI scenarios (no unit tests)"
    /// Live GitHub tests, but no offline tests.
    case liveTestsOnly = "Live GitHub tests only"
    /// Only a check in a verification record, or use by the user.
    case recordOnly = "A one-off scripted run or use (not repeatable)"
    /// Only inspection.
    case inspectionOnly = "Inspection only"
    /// Nothing yet.
    case none = "None yet"
    /// Not built yet.
    case proposed = "Proposed (not built)"
}

/// The references and gaps in one "Verified by" cell.
struct VerificationCell: Equatable, Sendable {
    /// The test references, in order.
    let tests: [TestReference]
    /// The UI scenarios cited as verifying the requirement, by name.
    let scenarios: [String]
    /// The UI scenarios named after `Gap` or in a `Planned` cell: ones still to write.
    let plannedScenarios: [String]
    /// The verification record checks, such as `V-2026-11-03/V10`.
    let recordChecks: [String]
    /// Whether the cell cites inspection (`I:`).
    let inspection: Bool
    /// Whether the cell cites use by the user (`U:`).
    let use: Bool
    /// Whether the cell notes a gap.
    let gap: Bool
    /// Whether the cell describes planned verification, as a proposed requirement's does.
    let planned: Bool

    /// Parses a "Verified by" cell.
    ///
    /// `T:` and `L:` references may continue with `, .test` for more tests in the same suite, and a whole-suite
    /// reference may claim its size with `(all N)`. A prefix only counts at the start of a word, so `UI:` isn't `I:`.
    /// A `UI:` reference after `Gap`, or anywhere in a cell that says `Planned`, is a scenario still to write.
    ///
    /// - Parameter text: The cell's text.
    init(_ text: String) {
        var tests: [TestReference] = []
        var last: (isLive: Bool, suite: String)?
        let pattern =
            #/(?:^|[^A-Za-z])(?<kind>[TL]):(?<suite>[A-Za-z_]\w*)(?:\.(?<test>[A-Za-z_]\w*))?(?:\s*\(all (?<all>\d+)\))?|,\s*\.(?<more>[A-Za-z_]\w*)/#
        for match in text.matches(of: pattern) {
            if let kind = match.kind, let suite = match.suite {
                let reference = TestReference(
                    isLive: kind == "L", suite: String(suite), test: match.test.map(String.init),
                    claimedCount: match.all.flatMap { Int($0) })
                tests.append(reference)
                last = (reference.isLive, reference.suite)
            } else if let more = match.more, let last {
                tests.append(TestReference(isLive: last.isLive, suite: last.suite, test: String(more), claimedCount: nil))
            }
        }
        self.tests = tests
        let scenarioPattern = #/(?:^|[^A-Za-z])UI:(?<name>[a-z0-9]+(?:-[a-z0-9]+)*)/#
        let gapStart = text.range(of: "Gap")?.lowerBound ?? text.endIndex
        var scenarios: [String] = []
        var plannedScenarios: [String] = []
        for match in text.matches(of: scenarioPattern) {
            let name = String(match.name)
            if text.contains("Planned") || match.range.lowerBound >= gapStart {
                plannedScenarios.append(name)
            } else {
                scenarios.append(name)
            }
        }
        self.scenarios = scenarios
        self.plannedScenarios = plannedScenarios
        recordChecks = DesignDocuments.recordCheckIDs(in: text)
        inspection = text.contains(#/(?:^|[^A-Za-z])I:/#)
        use = text.contains(#/(?:^|[^A-Za-z])U:/#)
        gap = text.contains("Gap")
        planned = text.contains("Planned")
    }

    /// Whether the cell says anything about verification: a reference, a gap, or a plan.
    var isEmpty: Bool { tests.isEmpty && scenarios.isEmpty && recordChecks.isEmpty && !inspection && !use && !gap && !planned }

    /// Classifies a requirement's coverage.
    ///
    /// - Parameter isProposed: Whether the requirement is proposed rather than built.
    /// - Returns: The coverage.
    func coverage(isProposed: Bool) -> Coverage {
        if isProposed { return .proposed }
        if tests.contains(where: { !$0.isLive }) { return gap ? .unitTestsPartly : .unitTests }
        if !scenarios.isEmpty { return .uiScenarios }
        if tests.contains(where: \.isLive) { return .liveTestsOnly }
        if !recordChecks.isEmpty || use { return .recordOnly }
        if inspection { return .inspectionOnly }
        return .none
    }
}

/// One Swift Testing test found in the repository's test sources.
struct TestCase: Equatable, Sendable {
    /// The suite: the enclosing type's name, or the file name for a test outside a type.
    let suite: String
    /// The test function's name.
    let name: String
    /// The display name given as `@Test("…")`, if any.
    let displayName: String?
    /// Whether the suite runs only against live GitHub (`MASER_LIVE_…`).
    let isLive: Bool
    /// Where the test is declared.
    let location: Location
}

/// One scripted UI scenario, declared in the app's scenario file.
struct UIScenarioCase: Equatable, Sendable {
    /// The scenario's name, as cited in `UI:name`.
    let name: String
    /// Its title, which names the requirements it verifies, like a test's display name.
    let title: String
    /// Where it's declared.
    let location: Location
}

/// Every test in the repository's `Tests` directory, and every UI scenario.
struct TestIndex: Sendable {
    /// The tests, in file and line order.
    let tests: [TestCase]
    /// The UI scenarios, in declaration order.
    let scenarios: [UIScenarioCase]

    /// The file declaring the UI scenarios, relative to the repository root.
    static let scenarioFile = "Sources/Maser/UIScenarios.swift"

    /// Finds the tests in every Swift file under `Tests/`.
    ///
    /// - Parameter root: The repository's root directory.
    /// - Returns: The index.
    /// - Throws: A file system error if a test file can't be read.
    static func load(root: URL) throws -> TestIndex {
        let testsURL = root.appending(path: "Tests")
        let paths = FileManager.default.enumerator(atPath: testsURL.path())?.compactMap { $0 as? String } ?? []
        var sources: [String: String] = [:]
        for path in paths.sorted() where path.hasSuffix(".swift") {
            sources["Tests/\(path)"] = try String(contentsOf: testsURL.appending(path: path), encoding: .utf8)
        }
        let scenarioSource = try? String(contentsOf: root.appending(path: scenarioFile), encoding: .utf8)
        return TestIndex(sources: sources, scenarioSource: scenarioSource)
    }

    /// Finds the tests in Swift sources already in memory.
    ///
    /// Relies on `swift format`'s layout: a type declared at column 0 is the suite for the indented `@Test`s after
    /// it, and a `@Test` at column 0 is a free function whose suite is its file's name. Lines inside multi-line string
    /// literals are skipped, so test code in fixtures isn't counted.
    ///
    /// - Parameters:
    ///   - sources: Each test file's source, by path.
    ///   - scenarioSource: The source of `scenarioFile`, if there is one.
    init(sources: [String: String], scenarioSource: String? = nil) {
        scenarios = scenarioSource.map { Self.scenarios(in: $0) } ?? []
        var tests: [TestCase] = []
        for (path, source) in sources.sorted(by: { $0.key < $1.key }) {
            let fileSuite = URL(filePath: path).deletingPathExtension().lastPathComponent
            var suite: (name: String, isLive: Bool)?
            var attributes = ""
            var pendingTest: (displayName: String?, line: Int)?
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // The delimiter that closes the multi-line string literal the current line is in, if any.
            var closingDelimiter: String?
            for (offset, line) in lines.enumerated() {
                if let closing = closingDelimiter {
                    if line.contains(closing) { closingDelimiter = nil }
                    continue
                }
                // A raw string (`#"""`) is closed only by `"""#`, so plain `"""` inside it doesn't end it.
                if line.contains("#\"\"\"") {
                    closingDelimiter = "\"\"\"#"
                    continue
                }
                if line.components(separatedBy: "\"\"\"").count.isMultiple(of: 2) {
                    closingDelimiter = "\"\"\""
                    continue
                }
                let atColumnZero = !(line.first?.isWhitespace ?? true)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if atColumnZero, let type = trimmed.firstMatch(of: #/(?:struct|final class|class|enum)\s+(\w+)/#) {
                    suite = (String(type.1), (attributes + line).contains("MASER_LIVE"))
                    attributes = ""
                } else if atColumnZero, trimmed.hasPrefix("@Suite") {
                    attributes += trimmed
                }
                if trimmed.hasPrefix("@Test") {
                    let displayName = trimmed.firstMatch(of: #/@Test\(\s*"([^"]*)"/#).map { String($0.1) }
                    pendingTest = (displayName, offset + 1)
                    if atColumnZero { suite = nil }
                }
                if let pending = pendingTest, let function = trimmed.firstMatch(of: #/\bfunc\s+(\w+)/#) {
                    tests.append(
                        TestCase(
                            suite: suite?.name ?? fileSuite, name: String(function.1), displayName: pending.displayName,
                            isLive: suite?.isLive ?? false, location: Location(file: path, line: pending.line)))
                    pendingTest = nil
                }
            }
        }
        self.tests = tests
    }

    /// Finds the scenarios declared as `UIScenario("name", "title")` in the scenario file.
    ///
    /// - Parameter source: The file's source.
    /// - Returns: The scenarios, in order.
    static func scenarios(in source: String) -> [UIScenarioCase] {
        source.matches(of: #/UIScenario\(\s*"(?<name>[^"]+)",\s*"(?<title>[^"]*)"/#).map { match in
            let line = source[..<match.range.lowerBound].count(where: { $0 == "\n" }) + 1
            return UIScenarioCase(
                name: String(match.name), title: String(match.title), location: Location(file: scenarioFile, line: line))
        }
    }

    /// The tests in a suite.
    ///
    /// - Parameter suite: The suite's name.
    /// - Returns: The suite's tests, in order.
    func tests(in suite: String) -> [TestCase] { tests.filter { $0.suite == suite } }
}
