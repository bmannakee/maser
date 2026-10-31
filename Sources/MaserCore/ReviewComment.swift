import Foundation

/// An inline review comment on a PR diff, from `GET /repos/{owner}/{repo}/pulls/{n}/comments`.
public struct ReviewComment: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let path: String
    /// Line in the current diff; `nil` when the comment is outdated.
    public let line: Int?
    public let originalLine: Int?
    public let side: DiffSide?
    public let inReplyToId: Int?
    public let user: String
    public let createdAt: Date
    public let body: String
    public let htmlUrl: URL

    /// jq filter that flattens each API page into one compact JSON object per line.
    static let jqFilter = """
    .[] | {id, path, line, original_line, side, in_reply_to_id, \
    user: (.user.login // "ghost"), created_at, body, html_url}
    """

    static func decodeLines(from data: Data) throws -> [ReviewComment] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try data.split(separator: UInt8(ascii: "\n")).map {
            try decoder.decode(ReviewComment.self, from: Data($0))
        }
    }
}

/// A root comment and its replies, oldest first.
public struct ReviewThread: Identifiable, Hashable, Sendable {
    public let comments: [ReviewComment]

    public var root: ReviewComment { comments[0] }
    public var id: Int { root.id }
    public var path: String { root.path }
    public var line: Int? { root.line }
    public var side: DiffSide { root.side ?? .right }
    public var isOutdated: Bool { root.line == nil }

    /// Groups flat comments into threads (GitHub points every reply at the thread's root),
    /// ordered by line, with outdated threads last.
    public static func group(_ comments: [ReviewComment]) -> [ReviewThread] {
        let ids = Set(comments.map(\.id))
        let replies = Dictionary(grouping: comments.filter { $0.inReplyToId.map(ids.contains) ?? false }) {
            $0.inReplyToId!
        }
        return comments
            .filter { !($0.inReplyToId.map(ids.contains) ?? false) }
            .map { root in
                ReviewThread(comments: [root] + (replies[root.id] ?? []).sorted { $0.createdAt < $1.createdAt })
            }
            .sorted {
                ($0.line ?? .max, $0.root.originalLine ?? .max, $0.root.createdAt)
                    < ($1.line ?? .max, $1.root.originalLine ?? .max, $1.root.createdAt)
            }
    }
}
