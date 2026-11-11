// Tests for keeping unsent text across crashes and quits.
//
// Each test uses a fresh temporary directory as the store, and PRs decoded from the JSON shape `gh search prs` prints.

import Foundation
import Testing

@testable import MaserCore

/// Tests for `UnsentText` and `UnsentTextStore`.
@Suite struct UnsentTextTests {
    /// A store in a new, empty temporary directory.
    let store = UnsentTextStore(
        directory: FileManager.default.temporaryDirectory.appending(path: "maser-unsent-\(UUID().uuidString)"))

    /// Decodes a PR in the shape `gh search prs --json` prints.
    ///
    /// - Parameters:
    ///   - repository: `owner/repo`.
    ///   - number: The PR number.
    ///   - host: The GitHub host.
    /// - Returns: The PR.
    /// - Throws: An error if the JSON doesn't decode.
    static func pr(_ repository: String, _ number: Int, host: String = "github.com") throws -> PullRequest {
        let name = repository.split(separator: "/").last.map(String.init) ?? repository
        let json = """
            [{"number":\(number),"title":"A change","url":"https://\(host)/\(repository)/pull/\(number)",
              "repository":{"name":"\(name)","nameWithOwner":"\(repository)"},"author":{"login":"octocat"},
              "updatedAt":"2026-11-10T12:00:00Z","isDraft":false}]
            """
        return try #require(try PullRequest.decodeList(from: Data(json.utf8)).first)
    }

    /// Unsent text with every part filled in.
    static let full = UnsentText(
        comment: "A conversation comment",
        lineComment: .init(
            target: .newThread(CommentTarget(path: "Sources/A.swift", side: .right, line: 12, startSide: .right, startLine: 10)),
            commitID: "4e5b8e054d5da90dc647db34891d6247c454f495", body: "On these lines"),
        reviewSummary: "Looks good")

    @Test("REQ-CMT-008: Saved text reads back, for each PR separately") func savesAndRestores() throws {
        let first = try Self.pr("bmannakee/maser", 1)
        let reply = UnsentText(lineComment: .init(target: .reply(threadID: "PRRT_1", to: "octocat"), commitID: nil, body: "Yes"))
        try store.save(Self.full, for: first)
        try store.save(reply, for: try Self.pr("bmannakee/maser", 2))

        #expect(try store.load(for: first) == Self.full)
        #expect(try store.load(for: Self.pr("bmannakee/maser", 2)) == reply)
        #expect(try store.load(for: Self.pr("bmannakee/other", 1)) == UnsentText())
        #expect(try store.load(for: Self.pr("bmannakee/maser", 1, host: "github.example.com")) == UnsentText())
    }

    @Test("REQ-CMT-008: Posting or discarding the last part removes the PR's file") func emptyTextRemovesFile() throws {
        let pr = try Self.pr("bmannakee/maser", 1)
        let path = store.fileURL(for: pr).path(percentEncoded: false)
        try store.save(Self.full, for: pr)
        #expect(FileManager.default.fileExists(atPath: path))

        try store.update(for: pr) { $0.comment = "" }
        try store.update(for: pr) { $0.lineComment = nil }
        #expect(FileManager.default.fileExists(atPath: path))
        // Whitespace alone isn't worth keeping.
        try store.update(for: pr) { $0.reviewSummary = "  \n" }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try store.load(for: pr) == UnsentText())
    }

    @Test("REQ-CMT-008: Changing one part keeps the parts another window wrote") func updateKeepsOtherParts() throws {
        let pr = try Self.pr("bmannakee/maser", 1)
        try store.update(for: pr) { $0.comment = "From the main window" }
        try store.update(for: pr) { $0.reviewSummary = "From another window" }
        #expect(try store.load(for: pr) == UnsentText(comment: "From the main window", reviewSummary: "From another window"))
    }

    @Test("REQ-CMT-008: A damaged file is reported on reading and replaced on the next save") func damagedFile() throws {
        let pr = try Self.pr("bmannakee/maser", 1)
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.fileURL(for: pr))
        #expect(throws: (any Error).self) { try store.load(for: pr) }

        try store.update(for: pr) { $0.comment = "New text" }
        #expect(try store.load(for: pr) == UnsentText(comment: "New text"))
    }
}
