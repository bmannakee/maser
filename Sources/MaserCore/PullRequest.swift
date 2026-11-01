// The summary of a pull request used in lists and to identify which PR a window shows.
//
// `PullRequest` holds the few fields `gh search prs` returns: enough to list PRs, open one, and find its repository
// and host for later `gh` calls. The full conversation lives in `PullRequestOverview`.

import Foundation

/// A pull request as returned by `gh search prs --json ...`.
public struct PullRequest: Codable, Hashable, Identifiable, Sendable {
    /// The repository a PR belongs to.
    public struct Repository: Codable, Hashable, Sendable {
        /// The repository name without its owner.
        public let name: String
        /// `owner/repo`.
        public let nameWithOwner: String
    }

    /// The account that opened a PR.
    public struct Author: Codable, Hashable, Sendable {
        /// The author's GitHub login.
        public let login: String
    }

    /// The PR number within its repository.
    public let number: Int
    /// The PR's title.
    public let title: String
    /// The PR's page on GitHub.
    public let url: URL
    /// The repository the PR belongs to.
    public let repository: Repository
    /// Who opened the PR.
    public let author: Author
    /// When the PR last changed.
    public let updatedAt: Date
    /// Whether the PR is a draft.
    public let isDraft: Bool

    /// The PR's URL, which is unique across repositories and hosts.
    public var id: URL { url }

    /// GitHub host the PR lives on (github.com or an Enterprise host).
    public var host: String { url.host() ?? "github.com" }

    /// Extracts the repository from a PR URL.
    ///
    /// `https://host/owner/repo/pull/123[/files…]` → `owner/repo`.
    ///
    /// - Parameter url: A link to a PR or one of its tabs.
    /// - Returns: `owner/repo`, or `nil` if the URL isn't a PR link.
    public static func nameWithOwner(fromURL url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull", Int(parts[3]) != nil else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// Fields to request from `gh` so the output decodes into this type.
    static let jsonFields = "number,title,url,repository,author,updatedAt,isDraft"

    /// Decodes the JSON array `gh` prints for `--json jsonFields`.
    ///
    /// - Parameter data: The command's standard output.
    /// - Returns: The PRs in the order `gh` listed them.
    /// - Throws: `DecodingError` if the JSON doesn't match.
    static func decodeList(from data: Data) throws -> [PullRequest] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PullRequest].self, from: data)
    }
}
