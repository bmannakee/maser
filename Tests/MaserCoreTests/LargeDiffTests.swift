// Tests for loading a PR's diff when GitHub refuses to serve it, with a stand-in `gh`.
//
// GitHub answers `gh pr diff` with HTTP 406 for a diff over 20,000 lines. `GitHubCLI.diffAtHead` then asks for the diff
// from the user's clone, with the base and head commits GitHub reports. These tests stand in for `gh` with a shell
// script and for the clone with a closure, and check what comes back and what is asked of the clone.

import Foundation
import Testing

@testable import MaserCore

/// Tests for the large-PR path of `GitHubCLI.diffAtHead`.
///
/// They extend `GitHubTimeoutTests` so they run serialized with it: both point `GitHubCLI`'s shared executable at a script.
extension GitHubTimeoutTests {
    /// What the stand-in `gh` says when GitHub refuses a diff, as the real one does.
    private static let refusal = """
        non-200 OK status code: 406 Not Acceptable body: "{\\"message\\":\\"Sorry, the diff exceeded the maximum number of \
        lines (20000)\\",\\"errors\\":[{\\"resource\\":\\"PullRequest\\",\\"field\\":\\"diff\\",\\"code\\":\\"too_large\\"}]}"
        """

    /// A small diff, as `gh pr diff` prints it.
    private static let smallDiff = """
        diff --git a/Door.swift b/Door.swift
        --- a/Door.swift
        +++ b/Door.swift
        @@ -1 +1 @@
        -struct Door {}
        +struct Door { var open = false }

        """

    /// Runs `body` with `GitHubCLI` pointed at a script that answers the context query and `pr diff`.
    ///
    /// - Parameters:
    ///   - diffOutput: What `gh pr diff` does: its output when it succeeds, or the refusal if nil.
    ///   - body: The test, given the PR to load.
    /// - Throws: Whatever `body` throws.
    private func withStandInGH(diffOutput: String?, _ body: (PullRequest) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "maser-large-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = #"""
            {"data":{"viewer":{"login":"octocat"},"repository":{"pullRequest":{"id":"PR_1","headRefOid":"headhead",
            "reviews":{"nodes":[]}}}}}
            """#
        try context.write(to: folder.appending(path: "context.json"), atomically: true, encoding: .utf8)
        try (diffOutput ?? "").write(to: folder.appending(path: "diff.txt"), atomically: true, encoding: .utf8)
        try Self.refusal.write(to: folder.appending(path: "refusal.txt"), atomically: true, encoding: .utf8)
        let failing = diffOutput == nil
        let script = """
            #!/bin/sh
            cd '\(folder.path(percentEncoded: false))'
            case "$1" in
            api) case "$*" in *baseRefOid*) echo basebase ;; *) cat context.json ;; esac ;;
            pr) if [ \(failing ? "1" : "0") = 1 ]; then cat refusal.txt >&2; exit 1; fi; cat diff.txt ;;
            *) echo "unexpected: $*" >&2; exit 2 ;;
            esac
            """
        let path = folder.appending(path: "gh")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path(percentEncoded: false))
        GitHubCLI.setConfiguredExecutable(path.path(percentEncoded: false))
        defer { GitHubCLI.setConfiguredExecutable(nil) }
        try await body(try AgentTests.pr("https://github.com/octocat/hello/pull/1"))
    }

    /// Records what the clone was asked for.
    private final class Asked: @unchecked Sendable {
        // Safe: each test awaits the call to finish before it reads this, and the call writes it once.
        var base: String?
        var head: String?
        var calls = 0
    }

    @Test("REQ-DIF-012: Recognizes GitHub's refusal of a large diff") func recognizesRefusal() {
        #expect(GitHubCLI.isDiffTooLarge(Self.refusal))
        #expect(GitHubCLI.isDiffTooLarge("HTTP 406: Sorry, the diff exceeded the maximum number of lines (20000)"))
        #expect(!GitHubCLI.isDiffTooLarge("HTTP 404: Not Found"))
        #expect(!GitHubCLI.isDiffTooLarge("HTTP 401: Bad credentials"))
    }

    @Test("REQ-DIF-012: Reads a refused diff from the clone, at the base and head GitHub reports")
    func readsFromClone() async throws {
        let asked = Asked()
        try await withStandInGH(diffOutput: nil) { pr in
            let result = try await GitHubCLI().diffAtHead(for: pr) { base, head in
                asked.base = base
                asked.head = head
                asked.calls += 1
                return Self.smallDiff
            }
            #expect(result.files.map(\.path) == ["Door.swift"])
            #expect(result.context.headCommitID == "headhead")
        }
        #expect(asked.base == "basebase")
        #expect(asked.head == "headhead")
        #expect(asked.calls == 1)
    }

    @Test("REQ-DIF-012: Doesn't touch the clone when GitHub serves the diff") func skipsCloneWhenServed() async throws {
        let asked = Asked()
        try await withStandInGH(diffOutput: Self.smallDiff) { pr in
            let result = try await GitHubCLI().diffAtHead(for: pr) { _, _ in
                asked.calls += 1
                return "diff --git a/Wrong.swift b/Wrong.swift\n"
            }
            #expect(result.files.map(\.path) == ["Door.swift"])
        }
        #expect(asked.calls == 0)
    }

    @Test("REQ-DIF-012: Says why, and how to fix it, when there is no clone") func saysWhyWithoutClone() async throws {
        try await withStandInGH(diffOutput: nil) { pr in
            for fromClone in [nil, { @Sendable (_: String, _: String) async throws -> String? in nil }] {
                let error = await #expect(throws: GitHubCLIError.self) {
                    try await GitHubCLI().diffAtHead(for: pr, diffFromClone: fromClone)
                }
                #expect(error == .diffTooLarge(repository: "octocat/hello"))
                let message = try #require(error?.errorDescription)
                #expect(message.contains("20,000 lines"))
                #expect(message.contains("octocat/hello"))
                #expect(message.contains("`repositories` under `[agent]`"))
            }
        }
    }

    @Test("REQ-DIF-012: Reports a clone that fails instead of showing nothing") func reportsCloneFailure() async throws {
        struct Broke: LocalizedError { var errorDescription: String? { "the commit isn't in your clone" } }
        try await withStandInGH(diffOutput: nil) { pr in
            let error = await #expect(throws: GitHubCLIError.self) {
                try await GitHubCLI().diffAtHead(for: pr) { _, _ in throw Broke() }
            }
            let message = try #require(error?.errorDescription)
            #expect(message.contains("reading it from your clone failed"))
            #expect(message.contains("the commit isn't in your clone"))
        }
    }
}
