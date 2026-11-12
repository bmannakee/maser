// Tests for the review agent's checkout, in throwaway git repositories.
//
// Each test builds an "origin" repository standing in for GitHub, and a "user clone" of it whose remote URL has the
// GitHub form, then checks what `AgentCheckout` does with them: where it fetches from, that the checkout is read-only
// with symlinks as plain files, and that the user's clone is left exactly as it was.

import Foundation
import Testing

@testable import MaserCore

/// Tests for `AgentCheckout`.
@Suite struct AgentCheckoutTests {
    /// The repository the fixtures pretend to be.
    static let repository = AgentCheckout.Repository(host: "github.com", owner: "Owner", name: "Repo")

    /// A temporary folder with an origin, a user clone, and a root for Maser's checkouts.
    struct Fixture {
        /// The temporary folder holding everything.
        let base: URL
        /// The origin repository, standing in for GitHub.
        let origin: URL
        /// The user's own clone, in a folder that `[agent] repositories` would name.
        let clone: URL
        /// The commit on the origin's main branch, which the clone has.
        let mainCommit: String
        /// A commit reachable only as `refs/pull/7/head` on the origin, as a PR from a fork is.
        let pullCommit: String
        /// Where Maser keeps its caches and checkouts.
        var checkout: AgentCheckout { AgentCheckout(root: base.appending(path: "maser")) }

        /// Builds the repositories.
        ///
        /// - Throws: A failure if a git command fails.
        init() async throws {
            base = FileManager.default.temporaryDirectory.appending(path: "maser-checkout-\(UUID().uuidString)")
            origin = base.appending(path: "origin")
            clone = base.appending(path: "dev").appending(path: "repo")
            try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: base.appending(path: "dev"), withIntermediateDirectories: true)
            let o = origin.path(percentEncoded: false)
            try await Self.git(["init", "--quiet", "--initial-branch=main", o])
            try "struct Door {}\n".write(to: origin.appending(path: "Door.swift"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(atPath: "\(o)/notes.txt", withDestinationPath: "../../outside/secret.txt")
            try await Self.git(["-C", o, "add", "-A"])
            try await Self.commit(o, "Door")
            mainCommit = try await Self.git(["-C", o, "rev-parse", "HEAD"])

            try await Self.git(["-C", o, "checkout", "--quiet", "-b", "feature"])
            try "struct Door { var open = false }\n".write(
                to: origin.appending(path: "Door.swift"), atomically: true, encoding: .utf8)
            try await Self.commit(o, "Open")
            pullCommit = try await Self.git(["-C", o, "rev-parse", "HEAD"])
            try await Self.git(["-C", o, "update-ref", "refs/pull/7/head", pullCommit])
            try await Self.git(["-C", o, "checkout", "--quiet", "main"])
            try await Self.git(["-C", o, "branch", "--quiet", "-D", "feature"])

            try await Self.git(["clone", "--quiet", o, clone.path(percentEncoded: false)])
            try await Self.git([
                "-C", clone.path(percentEncoded: false), "remote", "set-url", "origin", "git@github.com:Owner/Repo.git",
            ])
        }

        /// Removes everything, after making Maser's read-only checkouts writable again.
        func remove() {
            try? AgentCheckout.makeWritable(base)
            try? FileManager.default.removeItem(at: base)
        }

        /// Every file in the user's clone, including `.git`, with its size and modification time.
        var cloneSnapshot: [String: String] {
            var snapshot: [String: String] = [:]
            let enumerator = FileManager.default.enumerator(atPath: clone.path(percentEncoded: false))
            while let relative = enumerator?.nextObject() as? String {
                let attributes = enumerator?.fileAttributes ?? [:]
                snapshot[relative] = "\(attributes[.size] ?? 0) \(attributes[.modificationDate] ?? 0)"
            }
            return snapshot
        }

        /// Commits everything in a repository.
        ///
        /// - Parameters:
        ///   - repository: The repository's path.
        ///   - message: The commit message.
        /// - Throws: A failure if git fails.
        static func commit(_ repository: String, _ message: String) async throws {
            try await git([
                "-C", repository, "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-am",
                message,
            ])
        }

        /// Runs git, failing the test on a non-zero status.
        ///
        /// - Parameter arguments: The arguments.
        /// - Returns: Standard output, trimmed.
        /// - Throws: `Failure` with git's message.
        @discardableResult
        static func git(_ arguments: [String]) async throws -> String {
            let result = try await Subprocess.run(URL(filePath: "/usr/bin/git"), arguments)
            let output = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0 else {
                throw Failure(
                    description: "git \(arguments.joined(separator: " ")): \(String(decoding: result.stderr, as: UTF8.self))")
            }
            return output
        }

        /// A failed fixture step.
        struct Failure: Error, CustomStringConvertible {
            /// What failed.
            let description: String
        }
    }

    @Test("REQ-AGT-004: Reads remote URLs in GitHub's forms") func parsesRemoteURLs() {
        for remote in [
            "https://github.com/Owner/Repo.git", "https://github.com/owner/repo", "git@github.com:Owner/Repo.git",
            "ssh://git@github.com/Owner/Repo.git", "https://github.com/Owner/Repo/",
        ] {
            #expect(AgentCheckout.Repository(remoteURL: remote) == Self.repository, "\(remote)")
        }
        #expect(AgentCheckout.Repository(remoteURL: "git@github.example.com:team/svc.git")?.host == "github.example.com")
        for other in ["/Users/me/dev/repo", "https://github.com/Owner", "https://github.com/a/b/c", "nonsense"] {
            #expect(AgentCheckout.Repository(remoteURL: other) == nil, "\(other)")
        }
        #expect(Self.repository.httpsURL == "https://github.com/owner/repo.git")
    }

    @Test("REQ-AGT-004: Finds the user's clone by its remote") func findsClone() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let dev = fixture.base.appending(path: "dev").path(percentEncoded: false)
        let found = await fixture.checkout.findLocalClone(of: Self.repository, in: [dev])
        #expect(found?.standardizedFileURL == fixture.clone.standardizedFileURL)
        let other = AgentCheckout.Repository(host: "github.com", owner: "owner", name: "other")
        #expect(await fixture.checkout.findLocalClone(of: other, in: [dev]) == nil)
        #expect(await fixture.checkout.findLocalClone(of: Self.repository, in: ["/nonexistent"]) == nil)
    }

    /// The commit comes from the clone (the remote given doesn't exist), and the clone is left exactly as it was.
    @Test("REQ-AGT-004: Checks out from the user's clone, read-only, without changing it") func checksOutFromClone()
        async throws
    {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let before = fixture.cloneSnapshot
        let checkout = try await fixture.checkout.prepare(
            Self.repository, commit: fixture.mainCommit, pullNumber: 7, localClone: fixture.clone,
            remote: "/nonexistent/remote", credentialHelper: nil)

        #expect(fixture.cloneSnapshot == before)
        let door = checkout.appending(path: "Door.swift")
        #expect(try String(contentsOf: door, encoding: .utf8) == "struct Door {}\n")
        #expect(!FileManager.default.isWritableFile(atPath: door.path(percentEncoded: false)))
        #expect(!FileManager.default.isWritableFile(atPath: checkout.path(percentEncoded: false)))
        #expect(throws: (any Error).self) { try "changed".write(to: door, atomically: false, encoding: .utf8) }

        // The symlink in the commit is a plain file holding its target's path.
        let notes = checkout.appending(path: "notes.txt").path(percentEncoded: false)
        let type = try FileManager.default.attributesOfItem(atPath: notes)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
        #expect(try String(contentsOfFile: notes, encoding: .utf8) == "../../outside/secret.txt")

        // Asking again reuses the checkout.
        let again = try await fixture.checkout.prepare(
            Self.repository, commit: fixture.mainCommit, pullNumber: 7, localClone: nil, remote: "/nonexistent",
            credentialHelper: nil)
        #expect(again == checkout)
    }

    /// A commit only the PR's ref reaches, as for a PR from a fork, is fetched from the remote.
    @Test("REQ-AGT-004: Fetches a commit the clone lacks from the remote") func fetchesFromRemote() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let checkout = try await fixture.checkout.prepare(
            Self.repository, commit: fixture.pullCommit, pullNumber: 7, localClone: fixture.clone,
            remote: fixture.origin.path(percentEncoded: false), credentialHelper: nil)
        #expect(
            try String(contentsOf: checkout.appending(path: "Door.swift"), encoding: .utf8)
                == "struct Door { var open = false }\n")
        #expect(checkout.lastPathComponent == "repo@\(fixture.pullCommit.prefix(12))")
    }

    @Test("REQ-AGT-004: Says so when the commit is nowhere") func missingCommit() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let missing = String(repeating: "1", count: 40)
        await #expect(throws: AgentCheckout.Failure.commitNotFound(missing)) {
            try await fixture.checkout.prepare(
                Self.repository, commit: missing, pullNumber: 7, localClone: fixture.clone,
                remote: fixture.origin.path(percentEncoded: false), credentialHelper: nil)
        }
        #expect(AgentCheckout.Failure.commitNotFound(missing).errorDescription?.contains("force-pushed") == true)
    }
}
