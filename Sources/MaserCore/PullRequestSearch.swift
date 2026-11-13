// The searches behind the review queue, and how their results are grouped and filtered.
//
// The queue is a list of sections, each the result of one GitHub search: the built-in ones (review requested, yours,
// involving you) plus any from `[queue] searches` in `config.toml`. This file turns a search into `gh search prs`
// arguments, keeps a PR in only the first section that finds it, and narrows sections by the queue's filter text.

import Foundation

/// A named GitHub pull request search, shown as one section of the review queue.
public struct PullRequestSearch: Hashable, Sendable, Identifiable {
    /// The section's heading.
    public let name: String
    /// The search, in GitHub's search syntax, such as `repo:owner/name label:bug`.
    public let query: String

    /// Section names are unique; `Settings.load(toml:)` drops repeats.
    public var id: String { name }

    /// Creates a search.
    ///
    /// - Parameters:
    ///   - name: The section's heading.
    ///   - query: The search in GitHub's syntax. Open PRs only, unless it says otherwise (`is:closed`, `is:merged`).
    public init(name: String, query: String) {
        self.name = name
        self.query = query
    }

    /// Open PRs where the viewer's review is requested, directly or through a team.
    public static let reviewRequested = PullRequestSearch(name: "Review requested", query: "review-requested:@me")
    /// Open PRs the viewer wrote.
    public static let yours = PullRequestSearch(name: "Yours", query: "author:@me")
    /// Open PRs the viewer wrote, commented on, was mentioned in or is assigned to.
    public static let involving = PullRequestSearch(name: "Involving you", query: "involves:@me")

    /// The built-in searches by their names in `[queue] sections`, in their default order.
    public static let builtIns: KeyValuePairs<String, PullRequestSearch> = [
        "review-requested": reviewRequested,
        "yours": yours,
        "involving": involving,
    ]

    /// The search's words as separate `gh search prs` arguments, with `is:open` added unless it picks a state.
    ///
    /// Splits on spaces outside double quotes and drops the quotes; `gh` quotes each argument that has a space again,
    /// so `label:"needs review"` reaches GitHub intact.
    var searchWords: [String] {
        var words = Self.words(in: query)
        let picksState = words.contains { word in
            let lowered = word.lowercased().drop { $0 == "-" }
            return ["is:open", "is:closed", "is:merged", "is:unmerged"].contains(lowered) || lowered.hasPrefix("state:")
        }
        if !picksState { words.append("is:open") }
        return words
    }

    /// Splits a search into words, keeping double-quoted phrases together and removing their quotes.
    ///
    /// - Parameter query: A search in GitHub's syntax.
    /// - Returns: The words, such as `["label:needs review", "repo:o/r"]` for `label:"needs review" repo:o/r`.
    static func words(in query: String) -> [String] {
        var words: [String] = []
        var word = ""
        var inQuotes = false
        for character in query {
            if character == "\"" {
                inQuotes.toggle()
            } else if character.isWhitespace && !inQuotes {
                if !word.isEmpty { words.append(word) }
                word = ""
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }
}

/// One section of the review queue: a search and what it found.
public struct QueueSection: Identifiable, Sendable, Equatable {
    /// The search this section shows.
    public let search: PullRequestSearch
    /// The PRs found, most recently updated first; `nil` before the search first succeeds.
    public var prs: [PullRequest]?
    /// The message from the search's last failure, cleared by its next success.
    public var error: String?

    /// Sections are identified by their search's name.
    public var id: String { search.id }

    /// Creates a section.
    ///
    /// - Parameters:
    ///   - search: The search the section shows.
    ///   - prs: The PRs found, in any order; they're sorted most recently updated first.
    ///   - error: Why the last search failed, if it did.
    public init(search: PullRequestSearch, prs: [PullRequest]?, error: String? = nil) {
        self.search = search
        self.prs = prs?.sorted { $0.updatedAt > $1.updatedAt }
        self.error = error
    }

    /// Prepares sections for display: each PR only in the first section that has it, then narrowed by a filter.
    ///
    /// Sections left with no PRs and no error are dropped.
    ///
    /// - Parameters:
    ///   - sections: The sections in queue order.
    ///   - filter: Text typed in the queue's filter box; every word must match a PR's title, repository, author or
    ///     number (`#123` or `123`). Blank shows everything.
    /// - Returns: The sections to show.
    public static func displayed(_ sections: [QueueSection], filter: String = "") -> [QueueSection] {
        let words = filter.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        var seen: Set<PullRequest.ID> = []
        return sections.compactMap { section in
            var section = section
            section.prs = section.prs?.filter { pr in
                guard seen.insert(pr.id).inserted else { return false }
                return words.allSatisfy(pr.matches)
            }
            let isEmpty = section.prs?.isEmpty ?? true
            return isEmpty && section.error == nil ? nil : section
        }
    }
}

/// What the queue's last load knows about reviews requested of the viewer.
///
/// Only `clear` means nothing is waiting. Every other case leaves it unknown, or says something is.
public enum ReviewRequestStatus: Equatable, Sendable {
    /// The queue hasn't loaded, or the search has never succeeded.
    case unknown
    /// Review requested isn't one of the queue's sections.
    case notSearched
    /// The search's last run failed, with its message. It may still hold results from an earlier run.
    case failed(String)
    /// The search's last run succeeded and found nothing.
    case clear
    /// The search's last run succeeded and found this many PRs.
    case waiting(Int)
}

extension QueueSection {
    /// Reports whether reviews are requested of the viewer, from the built-in Review requested search.
    ///
    /// Pass the queue's own sections, not the result of `displayed(_:filter:)`: that drops PRs an earlier section
    /// already shows and PRs the filter hides, so its Review requested section can be empty while reviews wait.
    ///
    /// - Parameter sections: The queue's sections as loaded; `nil` before the first load.
    /// - Returns: `clear` only when the search's last run succeeded and found nothing.
    public static func reviewRequestStatus(in sections: [QueueSection]?) -> ReviewRequestStatus {
        guard let sections else { return .unknown }
        guard let section = sections.first(where: { $0.search == .reviewRequested }) else { return .notSearched }
        // A failed search keeps its last results, so check the error before trusting an empty list.
        if let error = section.error { return .failed(error) }
        guard let prs = section.prs else { return .unknown }
        return prs.isEmpty ? .clear : .waiting(prs.count)
    }
}

extension QueueSection {
    /// Finds the first PR of the next or previous section, for jumping between sections with the keyboard.
    ///
    /// Positions count PRs across all the sections in order, as the list shows them.
    ///
    /// - Parameters:
    ///   - index: The selected PR's position, or `nil` for none.
    ///   - sections: The sections as shown.
    ///   - forward: True for the next section, false for the previous one.
    /// - Returns: The position to select, or `nil` at the first or last section.
    public static func sectionStart(from index: Int?, in sections: [QueueSection], forward: Bool) -> Int? {
        var starts: [Int] = []
        var position = 0
        for section in sections {
            let count = section.prs?.count ?? 0
            if count > 0 { starts.append(position) }
            position += count
        }
        guard let index else { return forward ? starts.first : nil }
        if forward { return starts.first { $0 > index } }
        let current = starts.last { $0 <= index } ?? 0
        return starts.last { $0 < current }
    }

    /// Finds the PRs a refresh took out of the queue, such as ones merged or closed since the last load.
    ///
    /// A search that fails keeps its last results, so a failure never makes a PR look gone.
    ///
    /// - Parameters:
    ///   - old: The sections before the refresh; `nil` before the first load.
    ///   - new: The sections after it.
    /// - Returns: The IDs of PRs in some section before and in none after.
    public static func removedPRs(from old: [QueueSection]?, to new: [QueueSection]?) -> Set<PullRequest.ID> {
        let ids = { (sections: [QueueSection]?) in Set((sections ?? []).flatMap { $0.prs ?? [] }.map(\.id)) }
        return ids(old).subtracting(ids(new))
    }
}

extension PullRequest {
    /// Whether one word of the queue's filter matches the PR.
    ///
    /// - Parameter word: A lowercased filter word.
    /// - Returns: True if the title, `owner/name`, author login or number contains it; `#12` matches number 12 exactly.
    func matches(_ word: String) -> Bool {
        if word.hasPrefix("#") { return word == "#\(number)" }
        return title.lowercased().contains(word) || repository.nameWithOwner.lowercased().contains(word)
            || author.login.lowercased().contains(word) || String(number) == word
    }
}
