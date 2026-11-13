// Tests for the timeouts on `gh` calls: stopping a subprocess that runs too long, and telling reads from writes.
//
// A hung `gh` used to load forever (HAZ-12). `Subprocess.run` now stops a process that passes its timeout and says so,
// and `GitHubCLI.run` turns that into `GitHubCLIError.timedOut`, whose message warns when the call may have written.

import Foundation
import Testing

@testable import MaserCore

/// Tests for the subprocess timeout, telling writes from reads, and the timeout's messages.
@Suite struct GitHubTimeoutTests {
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
}
