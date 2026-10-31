import Foundation

/// A pull request as returned by `gh search prs --json ...`.
public struct PullRequest: Codable, Hashable, Identifiable, Sendable {
    public struct Repository: Codable, Hashable, Sendable {
        public let name: String
        public let nameWithOwner: String
    }

    public struct Author: Codable, Hashable, Sendable {
        public let login: String
    }

    public let number: Int
    public let title: String
    public let url: URL
    public let repository: Repository
    public let author: Author
    public let updatedAt: Date
    public let isDraft: Bool

    public var id: URL { url }

    /// GitHub host the PR lives on (github.com or an Enterprise host).
    public var host: String { url.host() ?? "github.com" }

    /// `https://host/owner/repo/pull/123[/files…]` → `owner/repo`.
    public static func nameWithOwner(fromURL url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull", Int(parts[3]) != nil else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    /// Fields to request from `gh` so the output decodes into this type.
    static let jsonFields = "number,title,url,repository,author,updatedAt,isDraft"

    static func decodeList(from data: Data) throws -> [PullRequest] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PullRequest].self, from: data)
    }
}
