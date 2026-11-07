// Tests for the review queue's searches: turning them into `gh` arguments, and grouping, filtering and navigating
// their results.

import Foundation
import Testing

@testable import MaserCore

/// Tests for `PullRequestSearch` and `QueueSection`.
@Suite struct PullRequestSearchTests {
    /// Builds a PR in `owner/repo` with the given number, title and author, updated `age` seconds ago.
    static func pr(_ number: Int, _ title: String = "A change", repo: String = "o/r", author: String = "ann", age: Double = 0)
        -> PullRequest
    {
        let json = """
            [{"author":{"login":"\(author)"},"isDraft":false,"number":\(number),
              "repository":{"name":"\(repo.split(separator: "/").last ?? "")","nameWithOwner":"\(repo)"},
              "title":"\(title)","updatedAt":"\(Date(timeIntervalSince1970: 1_800_000_000 - age).ISO8601Format())",
              "url":"https://github.com/\(repo)/pull/\(number)"}]
            """
        // The JSON above is built from known-good values, so it always decodes.
        return try! PullRequest.decodeList(from: Data(json.utf8))[0]
    }

    /// Splits on spaces outside quotes and drops the quotes, which `gh` puts back around words with spaces.
    @Test("REQ-QUE-001: Splits query into words") func splitsQueryIntoWords() {
        #expect(
            PullRequestSearch.words(in: #"repo:o/r  label:"needs review" "fix crash" -label:wip"#) == [
                "repo:o/r", "label:needs review", "fix crash", "-label:wip",
            ])
        #expect(PullRequestSearch.words(in: #"  "" a "#) == ["a"])
    }

    /// Searches open PRs unless the query picks a state, and puts the words after `--` so `-label:x` isn't a flag.
    @Test("REQ-QUE-001: gh arguments") func ghArguments() {
        let open = GitHubCLI.searchArguments(for: .reviewRequested, limit: 50)
        #expect(open.prefix(3) == ["search", "prs", "--limit"])
        #expect(open.suffix(3) == ["--", "review-requested:@me", "is:open"])

        let closed = PullRequestSearch(name: "Done", query: "repo:o/r is:Merged -label:wip")
        #expect(closed.searchWords == ["repo:o/r", "is:Merged", "-label:wip"])
        #expect(PullRequestSearch(name: "s", query: "state:closed").searchWords == ["state:closed"])
        #expect(PullRequestSearch(name: "d", query: "is:draft").searchWords == ["is:draft", "is:open"])
    }

    /// Keeps each PR only in the first section that has it, sorts by last update, and hides empty sections.
    @Test("REQ-QUE-002, REQ-QUE-004: Displayed deduplicates") func displayedDeduplicates() {
        let sections = [
            QueueSection(search: .reviewRequested, prs: [Self.pr(1, age: 100), Self.pr(2, age: 10)]),
            QueueSection(search: .yours, prs: [Self.pr(2), Self.pr(3)]),
            QueueSection(search: .involving, prs: [Self.pr(1)]),
            QueueSection(search: PullRequestSearch(name: "Broken", query: "x"), prs: nil, error: "bad query"),
        ]
        let shown = QueueSection.displayed(sections)
        #expect(shown.map(\.id) == ["Review requested", "Yours", "Broken"])
        #expect(shown[0].prs?.map(\.number) == [2, 1])
        #expect(shown[1].prs?.map(\.number) == [3])
        #expect(shown[2].error == "bad query")
    }

    /// Every filter word must match the title, repository, author or number.
    @Test("REQ-QUE-003: Filters") func filters() {
        let sections = [
            QueueSection(
                search: .reviewRequested,
                prs: [
                    Self.pr(12, "Fix the parser", repo: "acme/api", author: "bo"),
                    Self.pr(120, "Add docs", repo: "acme/web", author: "cy"),
                    Self.pr(7, "Parser tests", repo: "other/tool", author: "bo"),
                ])
        ]
        func numbers(_ filter: String) -> [Int] {
            QueueSection.displayed(sections, filter: filter).flatMap { $0.prs ?? [] }.map(\.number).sorted()
        }
        #expect(numbers("") == [7, 12, 120])
        #expect(numbers("PARSER") == [7, 12])
        #expect(numbers("parser acme") == [12])
        #expect(numbers("bo") == [7, 12])
        #expect(numbers("#12") == [12])
        #expect(numbers("12") == [12])
        #expect(numbers("acme/web") == [120])
        #expect(numbers("nothing").isEmpty)
        #expect(QueueSection.displayed(sections, filter: "nothing").isEmpty)
    }

    /// Jumps to the first PR of the next or previous section, skipping empty ones and stopping at either end.
    @Test("REQ-QUE-007: Section starts") func sectionStarts() {
        // Positions: section A is 0–1, B is empty, C is 2–4.
        let sections = [
            QueueSection(search: .reviewRequested, prs: [Self.pr(1), Self.pr(2)]),
            QueueSection(search: .yours, prs: []),
            QueueSection(search: .involving, prs: [Self.pr(3), Self.pr(4), Self.pr(5)]),
        ]
        #expect(QueueSection.sectionStart(from: nil, in: sections, forward: true) == 0)
        #expect(QueueSection.sectionStart(from: 0, in: sections, forward: true) == 2)
        #expect(QueueSection.sectionStart(from: 1, in: sections, forward: true) == 2)
        #expect(QueueSection.sectionStart(from: 3, in: sections, forward: true) == nil)
        #expect(QueueSection.sectionStart(from: 4, in: sections, forward: false) == 0)
        #expect(QueueSection.sectionStart(from: 2, in: sections, forward: false) == 0)
        #expect(QueueSection.sectionStart(from: 1, in: sections, forward: false) == nil)
        #expect(QueueSection.sectionStart(from: nil, in: sections, forward: false) == nil)
    }
}

/// Read-only test of the queue's searches against real GitHub.
///
/// Run with `MASER_LIVE_TESTS=1 swift test`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MASER_LIVE_TESTS"] != nil))
struct LivePullRequestSearchTests {
    /// Finds this repo's merged PRs with a search that picks a state, and runs every built-in search.
    @Test("REQ-QUE-001: Searches") func searches() async throws {
        let cli = GitHubCLI()
        let merged = try await cli.searchPullRequests(
            PullRequestSearch(name: "Merged", query: "repo:bmannakee/maser is:merged"), limit: 5)
        #expect(!merged.isEmpty)
        #expect(merged.allSatisfy { $0.repository.nameWithOwner == "bmannakee/maser" })
        for search in PullRequestSearch.builtIns.map(\.value) {
            _ = try await cli.searchPullRequests(search, limit: 5)
        }
        // A quoted phrase must reach GitHub as one phrase.
        let quoted = try await cli.searchPullRequests(
            PullRequestSearch(name: "Quoted", query: #"repo:bmannakee/maser is:merged in:title "lower minimums""#), limit: 5)
        #expect(quoted.map(\.number) == [10])
    }
}
