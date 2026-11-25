// Tests for reading a PR's diff from the user's clone, in throwaway git repositories.
//
// GitHub refuses diffs over 20,000 lines, so maser computes them with `git diff` instead. These tests use the same
// origin-and-clone fixture as the checkout tests, with a 25,000-line PR added, and check the diff's text, that it follows
// the commits it is given rather than local refs, that the user's git settings can't change it, and that the clone is
// left alone.

import Foundation
import Testing

@testable import MaserCore

/// Tests for `AgentCheckout.diff`.
///
/// Serialized because one test sets `GIT_CONFIG_GLOBAL` for the whole process.
@Suite(.serialized) struct LocalDiffTests {
    /// Adds a PR to the origin whose head is a 25,000-line file on top of the origin's main commit.
    ///
    /// - Parameter fixture: The fixture to add it to.
    /// - Returns: The new head commit; the PR's ref is `refs/pull/8/head`.
    /// - Throws: A failure if a git command fails.
    private static func addLargePull(to fixture: AgentCheckoutTests.Fixture) async throws -> String {
        let o = fixture.origin.path(percentEncoded: false)
        try await AgentCheckoutTests.Fixture.git(["-C", o, "checkout", "--quiet", "-b", "large", fixture.mainCommit])
        let lines = (1...25_000).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try lines.write(to: fixture.origin.appending(path: "Big.txt"), atomically: true, encoding: .utf8)
        try await AgentCheckoutTests.Fixture.git(["-C", o, "add", "-A"])
        try await AgentCheckoutTests.Fixture.commit(o, "Big")
        let head = try await AgentCheckoutTests.Fixture.git(["-C", o, "rev-parse", "HEAD"])
        try await AgentCheckoutTests.Fixture.git(["-C", o, "update-ref", "refs/pull/8/head", head])
        try await AgentCheckoutTests.Fixture.git(["-C", o, "checkout", "--quiet", "main"])
        try await AgentCheckoutTests.Fixture.git(["-C", o, "branch", "--quiet", "-D", "large"])
        return head
    }

    /// A PR over GitHub's 20,000-line limit is read from the user's clone, fetching its head from the remote.
    @Test("REQ-DIF-012: Computes a diff over 20,000 lines from the clone") func diffsALargePull() async throws {
        let fixture = try await AgentCheckoutTests.Fixture()
        defer { fixture.remove() }
        let head = try await Self.addLargePull(to: fixture)
        let before = fixture.cloneSnapshot
        let text = try await fixture.checkout.diff(
            AgentCheckoutTests.repository, base: fixture.mainCommit, head: head, pullNumber: 8, localClone: fixture.clone,
            remote: fixture.origin.path(percentEncoded: false), credentialHelper: nil)

        let files = DiffParser.parse(text)
        #expect(files.map(\.path) == ["Big.txt"])
        #expect(files.first?.status == .added)
        #expect(files.first?.additions == 25_000)
        // The user's own clone is only read (RC-23).
        #expect(fixture.cloneSnapshot == before)
    }

    /// The commits come from the API, not from refs, because the clone's refs may be stale or moved.
    @Test("REQ-DIF-012: Diffs the commits it is given, whatever the clone's refs say") func ignoresStaleRefs() async throws {
        let fixture = try await AgentCheckoutTests.Fixture()
        defer { fixture.remove() }
        // The clone's main now holds a different change to the same file, as a stale or locally edited branch would.
        let c = fixture.clone.path(percentEncoded: false)
        try "struct Door { var local = true }\n".write(
            to: fixture.clone.appending(path: "Door.swift"), atomically: true, encoding: .utf8)
        try await AgentCheckoutTests.Fixture.commit(c, "Local edit")
        let text = try await fixture.checkout.diff(
            AgentCheckoutTests.repository, base: fixture.mainCommit, head: fixture.pullCommit, pullNumber: 7,
            localClone: fixture.clone,
            remote: fixture.origin.path(percentEncoded: false), credentialHelper: nil)

        let hunks = try #require(DiffParser.parse(text).first?.hunks)
        let lines = hunks.flatMap(\.lines)
        let changed = lines.filter { $0.kind != .context }.map(\.text)
        #expect(changed == ["struct Door {}", "struct Door { var open = false }"])
    }

    /// Git's own settings, such as `diff.noprefix` or a color setting, don't change the text the parser reads.
    @Test("REQ-DIF-012: The diff text doesn't depend on the user's git config") func independentOfGitConfig() async throws {
        let fixture = try await AgentCheckoutTests.Fixture()
        defer { fixture.remove() }
        let home = fixture.base.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "[diff]\n\tnoprefix = true\n\tmnemonicPrefix = true\n[color]\n\tui = always\n".write(
            to: home.appending(path: ".gitconfig"), atomically: true, encoding: .utf8)
        setenv("GIT_CONFIG_GLOBAL", home.appending(path: ".gitconfig").path(percentEncoded: false), 1)
        defer { unsetenv("GIT_CONFIG_GLOBAL") }
        let text = try await fixture.checkout.diff(
            AgentCheckoutTests.repository, base: fixture.mainCommit, head: fixture.pullCommit, pullNumber: 7,
            localClone: fixture.clone,
            remote: fixture.origin.path(percentEncoded: false), credentialHelper: nil)
        #expect(text.contains("diff --git a/Door.swift b/Door.swift"))
        #expect(!text.contains("\u{1B}["))
    }

    @Test("REQ-DIF-012: Says so when a commit is nowhere") func diffWithMissingCommit() async throws {
        let fixture = try await AgentCheckoutTests.Fixture()
        defer { fixture.remove() }
        let missing = String(repeating: "2", count: 40)
        await #expect(throws: AgentCheckout.Failure.commitNotFound(missing)) {
            try await fixture.checkout.diff(
                AgentCheckoutTests.repository, base: fixture.mainCommit, head: missing, pullNumber: 7, localClone: fixture.clone,
                remote: "/nonexistent", credentialHelper: nil)
        }
    }
}
