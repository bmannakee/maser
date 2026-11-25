// Tests for reading a file at a commit from the user's clone, in throwaway git repositories.
//
// Show Full File asks the clone first, because that saves a GitHub call per file. These tests use the origin-and-clone
// fixture of the checkout tests and check what comes back, that anything uncertain gives nil so GitHub is asked instead,
// and that the clone is never written to, not even to fetch a commit it lacks.

import Foundation
import Testing

@testable import MaserCore

/// Tests for `AgentCheckout.fileContents(inClone:commit:path:maxBytes:)`.
@Suite struct CloneFileTests {
    @Test("REQ-DIF-013: Reads a file at a commit the clone has, without changing the clone") func readsFromClone() async throws {
        let fixture = try await AgentCheckoutTests.Fixture()
        defer { fixture.remove() }
        let before = fixture.cloneSnapshot
        let text = await fixture.checkout.fileContents(
            inClone: fixture.clone, commit: fixture.mainCommit, path: "Door.swift", maxBytes: 4_000_000)
        #expect(text == "struct Door {}\n")
        #expect(fixture.cloneSnapshot == before)
    }

    @Test("REQ-DIF-013: Gives nil, and fetches nothing, for a commit the clone lacks") func lacksCommit() async throws {
        let fixture = try await AgentCheckoutTests.Fixture()
        defer { fixture.remove() }
        // A commit made on the origin after the clone, as a PR the user hasn't fetched is. (A fresh local clone shares
        // all of the origin's objects, so the fixture's own pull commit is in it.)
        let o = fixture.origin.path(percentEncoded: false)
        try "struct Door { var later = true }\n".write(
            to: fixture.origin.appending(path: "Door.swift"), atomically: true, encoding: .utf8)
        try await AgentCheckoutTests.Fixture.commit(o, "Later")
        let later = try await AgentCheckoutTests.Fixture.git(["-C", o, "rev-parse", "HEAD"])
        let before = fixture.cloneSnapshot
        let text = await fixture.checkout.fileContents(
            inClone: fixture.clone, commit: later, path: "Door.swift", maxBytes: 4_000_000)
        #expect(text == nil)
        #expect(fixture.cloneSnapshot == before)
    }

    @Test("REQ-DIF-013: Gives nil for anything but a regular file") func onlyRegularFiles() async throws {
        let fixture = try await AgentCheckoutTests.Fixture()
        defer { fixture.remove() }
        for path in ["notes.txt", ".", "", "missing.swift", "-p", "Door.swift/../Door.swift"] {
            let text = await fixture.checkout.fileContents(
                inClone: fixture.clone, commit: fixture.mainCommit, path: path, maxBytes: 4_000_000)
            #expect(text == nil, "\(path)")
        }
        for commit in ["", "not-hex", "--all", "HEAD"] {
            let text = await fixture.checkout.fileContents(
                inClone: fixture.clone, commit: commit, path: "Door.swift", maxBytes: 4_000_000)
            #expect(text == nil, "\(commit)")
        }
    }

    @Test("REQ-DIF-013: Gives nil for a file over the limit, so GitHub's path reports it") func overLimit()
        async throws
    {
        let fixture = try await AgentCheckoutTests.Fixture()
        defer { fixture.remove() }
        let text = await fixture.checkout.fileContents(
            inClone: fixture.clone, commit: fixture.mainCommit, path: "Door.swift", maxBytes: 5)
        #expect(text == nil)
    }
}
