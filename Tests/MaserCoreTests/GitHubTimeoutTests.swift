// Tests for the timeouts on `gh` calls: stopping a subprocess that runs too long, and telling reads from writes.
//
// A hung `gh` used to load forever (HAZ-12). `Subprocess.run` now stops a process that passes its timeout and says so,
// and `GitHubCLI.run` turns that into `GitHubCLIError.timedOut`, whose message warns when the call may have written.
// The stand-ins for a hung `gh` are shell scripts: ones that ignore or catch SIGTERM, and ones that leave a child
// holding the output pipes, as the review agent pointed out a real `gh` might.

import Foundation
import Testing

@testable import MaserCore

/// Tests for the subprocess timeout, telling writes from reads, and the timeout's messages.
///
/// Serialized because the tests through `GitHubCLI` point its shared executable at a stalling script.
@Suite(.serialized) struct GitHubTimeoutTests {
    /// Runs a shell script with a short timeout and grace.
    ///
    /// - Parameter script: The script for `/bin/sh -c`.
    /// - Returns: The result, and how long the run took.
    /// - Throws: The error from launching it.
    private func runStalling(_ script: String) async throws -> (Subprocess.Result, Duration) {
        let start = ContinuousClock.now
        let result = try await Subprocess.run(
            URL(filePath: "/bin/sh"), ["-c", script], timeout: .milliseconds(300), killGrace: .milliseconds(300))
        return (result, ContinuousClock.now - start)
    }

    @Test("REQ-GH-007: Kills a process that ignores SIGTERM") func killsAProcessIgnoringTerm() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "maser-ignores-term-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let (result, elapsed) = try await runStalling(
            "echo $$ > '\(pidFile.path(percentEncoded: false))'; trap '' TERM; while :; do sleep 0.1; done")
        #expect(result.timedOut)
        #expect(elapsed < .seconds(5))
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Giving up on the pipes would also end the wait, so check the process itself is gone.
        var alive = true
        for _ in 0..<20 where alive {
            alive = kill(pid, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(!alive)
    }

    @Test("REQ-GH-007: A process that catches SIGTERM and exits with its own status still timed out")
    func catchingTermStillTimesOut() async throws {
        let (result, elapsed) = try await runStalling("trap 'exit 3' TERM; while :; do sleep 0.1; done")
        #expect(result.timedOut)
        #expect(result.status == 3)
        #expect(elapsed < .seconds(5))
    }

    @Test("REQ-GH-007: Stops waiting when a child holds the output pipes open") func childHoldingPipes() async throws {
        // The child leaves the process group, as a daemonizing helper would, so stopping the group doesn't reach it.
        let (result, elapsed) = try await runStalling(
            "/usr/bin/perl -e 'setpgrp(0, 0); sleep 8' & while :; do sleep 0.1; done")
        #expect(result.timedOut)
        #expect(elapsed < .seconds(4))
    }

    @Test("REQ-GH-007: Stops a process that runs past its timeout") func stopsAHungProcess() async throws {
        let start = ContinuousClock.now
        let result = try await Subprocess.run(URL(filePath: "/bin/sleep"), ["30"], timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("REQ-GH-007: A process that finishes in time isn't marked timed out") func finishesInTime() async throws {
        let result = try await Subprocess.run(URL(filePath: "/bin/echo"), ["hello"], timeout: .seconds(10))
        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello\n")
    }

    @Test("REQ-GH-007: A process that fails by itself isn't marked timed out") func failureIsNotATimeout() async throws {
        let result = try await Subprocess.run(URL(filePath: "/bin/sh"), ["-c", "kill -TERM $$"], timeout: .seconds(10))
        #expect(!result.timedOut)
        #expect(result.status != 0)
    }

    @Test("REQ-GH-007: Tells calls that change GitHub from reads") func tellsWritesFromReads() {
        #expect(GitHubCLI.isWrite(["api", "--hostname", "github.com", "--method", "POST", "repos/o/r/issues/1/comments"]))
        #expect(GitHubCLI.isWrite(["api", "graphql", "--hostname", "github.com", "-f", "query=mutation { deleteThing }"]))
        // Maser's own mutations take variables, so the keyword is followed by "(".
        #expect(GitHubCLI.isWrite(["api", "graphql", "-f", "id=X", "-f", "query=mutation($id: ID!) { deleteThing }"]))
        #expect(GitHubCLI.isWrite(["api", "graphql", "-f", "query=\n  mutation Named { deleteThing }"]))
        #expect(!GitHubCLI.isWrite(["api", "graphql", "-f", "query=mutationsQuery { viewer { login } }"]))
        #expect(!GitHubCLI.isWrite(["api", "--method", "GET", "repos/o/r/pulls/1"]))
        #expect(!GitHubCLI.isWrite(["api", "graphql", "-f", "query=query { viewer { login } }"]))
        #expect(!GitHubCLI.isWrite(["pr", "diff", "1", "--repo", "github.com/o/r", "--color", "never"]))
        #expect(!GitHubCLI.isWrite(["search", "prs", "--review-requested", "@me"]))
    }

    @Test("REQ-GH-007: Says a timed-out write may have reached GitHub") func messages() {
        let read = GitHubCLIError.timedOut(seconds: 60, mayHaveWritten: false).errorDescription ?? ""
        #expect(read.contains("within 60 seconds"))
        #expect(read.contains("try again"))
        #expect(!read.contains("may still have received"))
        let write = GitHubCLIError.timedOut(seconds: 60, mayHaveWritten: true).errorDescription ?? ""
        #expect(write.contains("GitHub may still have received it"))
        #expect(write.contains("check before posting again"))
    }

    /// Points `GitHubCLI` at a script that never answers, runs a call through it with a 1-second timeout, and restores
    /// the defaults.
    ///
    /// - Parameter call: The call, given a client and a PR.
    /// - Returns: The error the call threw, or nil if it didn't throw.
    /// - Throws: Errors writing the script, or an error the call threw that isn't a `GitHubCLIError`.
    private func timedOutError(_ call: (GitHubCLI, PullRequest) async throws -> Void) async throws -> GitHubCLIError? {
        let folder = FileManager.default.temporaryDirectory.appending(path: "maser-stalling-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appending(path: "gh")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        GitHubCLI.setConfiguredExecutable(script.path(percentEncoded: false))
        GitHubCLI.setTimeout(seconds: 1)
        defer {
            GitHubCLI.setConfiguredExecutable(nil)
            GitHubCLI.setTimeout(seconds: Settings.defaults.ghTimeoutSeconds)
        }
        do {
            try await call(GitHubCLI(), try AgentTests.pr("https://github.com/octocat/hello/pull/1"))
            return nil
        } catch let error as GitHubCLIError {
            return error
        }
    }

    /// Whether live tests are running; they share the `gh` executable this suite replaces.
    static let isLive = ProcessInfo.processInfo.environment["MASER_LIVE_TESTS"] != nil

    @Test("REQ-GH-007: Maser's own writes and reads are told apart when they time out", .disabled(if: Self.isLive))
    func realCallsTimeOut() async throws {
        let post = try await timedOutError { cli, pr in try await cli.addComment(to: pr, body: "hello") }
        #expect(post == .timedOut(seconds: 1, mayHaveWritten: true))
        let delete = try await timedOutError { cli, pr in try await cli.deleteReviewComment(on: pr, commentID: "PRRC_1") }
        #expect(delete == .timedOut(seconds: 1, mayHaveWritten: true))
        let discard = try await timedOutError { cli, pr in try await cli.discardReview(on: pr, reviewID: "PRR_1") }
        #expect(discard == .timedOut(seconds: 1, mayHaveWritten: true))
        let diff = try await timedOutError { cli, pr in _ = try await cli.fileDiffs(for: pr) }
        #expect(diff == .timedOut(seconds: 2, mayHaveWritten: false))
    }
}
