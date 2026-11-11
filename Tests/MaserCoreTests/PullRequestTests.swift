// Tests for `PullRequest`: decoding the `gh search prs` list and reading the repository from a PR URL.

import Foundation
import Testing

@testable import MaserCore

@Test("REQ-QUE-001: Decodes gh search output") func decodesGhSearchOutput() throws {
    let json = """
        [{"author":{"id":"MDQ6VXNlcjIxODAxMTg=","is_bot":false,"login":"octocat","type":"User","url":"https://github.com/octocat"},
          "isDraft":false,"number":351,"repository":{"name":"broom","nameWithOwner":"tidymodels/broom"},
          "title":"Fix a thing","updatedAt":"2021-03-11T00:21:48Z","url":"https://github.com/tidymodels/broom/pull/351"}]
        """
    let prs = try PullRequest.decodeList(from: Data(json.utf8))

    #expect(prs.count == 1)
    let pr = try #require(prs.first)
    #expect(pr.number == 351)
    #expect(pr.repository.nameWithOwner == "tidymodels/broom")
    #expect(pr.author.login == "octocat")
    #expect(pr.isDraft == false)
    #expect(pr.url == URL(string: "https://github.com/tidymodels/broom/pull/351"))
}

/// Reads `owner/repo` from PR URLs on any host, including ones with trailing components, and rejects non-PR URLs.
@Test("REQ-GH-006: Name with owner from URL") func nameWithOwnerFromURL() {
    #expect(PullRequest.nameWithOwner(fromURL: URL(string: "https://github.com/cli/cli/pull/14858")!) == "cli/cli")
    #expect(PullRequest.nameWithOwner(fromURL: URL(string: "https://ghe.example.com/team/app/pull/7/files")!) == "team/app")
    #expect(PullRequest.nameWithOwner(fromURL: URL(string: "https://github.com/cli/cli/issues/1")!) == nil)
    #expect(PullRequest.nameWithOwner(fromURL: URL(string: "https://github.com/cli")!) == nil)
}

@Test("REQ-GH-004: Decodes empty result") func decodesEmptyResult() throws {
    #expect(try PullRequest.decodeList(from: Data("[]".utf8)).isEmpty)
}
