// The `maser-trace` command: checks the links between Maser's requirements, risks, tests and verification records.
//
// Run from the repository root (`scripts/check` does). With `--write` it first regenerates the generated sections of
// docs/design/traceability.md. It prints each problem as `file:line: message [rule]` and exits non-zero if there are
// any, so it can gate commits.

import Foundation
import Traceability

let arguments = CommandLine.arguments.dropFirst()
if arguments.contains("-h") || arguments.contains("--help") {
    print(
        """
        Usage: maser-trace [--write]

        Checks docs/design/ against itself, the tests in Tests/, and the records in docs/verification/.
          --write   regenerate the generated sections of docs/design/traceability.md first
        """)
    exit(0)
}
let unknown = arguments.filter { $0 != "--write" }
guard unknown.isEmpty else {
    FileHandle.standardError.write(Data("maser-trace: unknown argument \(unknown.joined(separator: " "))\n".utf8))
    exit(2)
}

do {
    let root = URL(filePath: FileManager.default.currentDirectoryPath)
    let outcome = try TraceReport.check(root: root, write: arguments.contains("--write"))
    if outcome.rewrote { print("Updated docs/design/traceability.md") }
    for problem in outcome.problems { print(problem) }
    print("Traceability: \(outcome.summary).")
    if outcome.problems.isEmpty {
        print("No problems.")
    } else {
        print("\(outcome.problems.count) problem\(outcome.problems.count == 1 ? "" : "s").")
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("maser-trace: \(error.localizedDescription)\n".utf8))
    exit(2)
}
