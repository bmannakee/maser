import Foundation

/// A comment in an inline review thread. `isPending` means it's in the viewer's unsubmitted review.
public struct ReviewComment: Identifiable, Hashable, Sendable {
    /// GraphQL node ID (used to delete a pending comment).
    public let id: String
    public let author: String
    public let body: String
    public let createdAt: Date
    public let url: URL?
    public let isPending: Bool
}

/// An inline review thread on a PR diff, from GraphQL `reviewThreads` (which, unlike the REST API,
/// includes the viewer's pending comments along with their side and line range).
public struct ReviewThread: Identifiable, Hashable, Sendable {
    /// GraphQL node ID (used to reply).
    public let id: String
    public let path: String
    /// Line in the current diff (the last line, for a range); `nil` when the thread is outdated.
    public let line: Int?
    public let startLine: Int?
    public let originalLine: Int?
    public let side: DiffSide
    public let isOutdated: Bool
    public let isResolved: Bool
    public let comments: [ReviewComment]

    public var root: ReviewComment { comments[0] }
    /// Whether the thread itself is a draft (as opposed to a draft reply on a posted thread).
    public var isPending: Bool { root.isPending }
    public var hasPendingComments: Bool { comments.contains(where: \.isPending) }

    /// The thread without the viewer's draft comments; nil if nothing is left (it was a draft thread).
    /// GitHub takes a few seconds to reflect a discarded review, so the app applies this locally.
    public func removingPendingComments() -> ReviewThread? {
        let posted = comments.filter { !$0.isPending }
        guard !posted.isEmpty else { return nil }
        return ReviewThread(copying: self, comments: posted)
    }

    private init(copying thread: ReviewThread, comments: [ReviewComment]) {
        id = thread.id
        path = thread.path
        line = thread.line
        startLine = thread.startLine
        originalLine = thread.originalLine
        side = thread.side
        isOutdated = thread.isOutdated
        isResolved = thread.isResolved
        self.comments = comments
    }

    /// One compact JSON object per thread per line, from paginated GraphQL output.
    static let jqFilter = ".data.repository.pullRequest.reviewThreads.nodes[]"

    static let query = """
        query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewThreads(first: 100, after: $endCursor) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id path line startLine originalLine diffSide isOutdated isResolved
                  comments(first: 100) { nodes { id author { login } body createdAt url state } }
                }
              }
            }
          }
        }
        """

    static func decodeLines(from data: Data) throws -> [ReviewThread] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: UInt8(ascii: "\n")).compactMap {
            ReviewThread(try decoder.decode(Raw.self, from: Data($0)))
        }
        .sorted {
            ($0.line ?? .max, $0.originalLine ?? .max, $0.root.createdAt)
                < ($1.line ?? .max, $1.originalLine ?? .max, $1.root.createdAt)
        }
    }

    private init?(_ raw: Raw) {
        let comments = raw.comments.nodes.compactMap(\.self).map { comment in
            ReviewComment(
                id: comment.id,
                author: comment.author?.login ?? "ghost",
                body: comment.body,
                createdAt: comment.createdAt,
                url: comment.url.flatMap(URL.init(string:)),
                isPending: comment.state == "PENDING"
            )
        }
        guard !comments.isEmpty else { return nil }
        id = raw.id
        path = raw.path
        line = raw.line
        startLine = raw.startLine
        originalLine = raw.originalLine
        side = DiffSide(rawValue: raw.diffSide) ?? .right
        isOutdated = raw.isOutdated || raw.line == nil
        isResolved = raw.isResolved
        self.comments = comments
    }

    private struct Raw: Decodable {
        struct Nodes: Decodable { let nodes: [Comment?] }
        struct Actor: Decodable { let login: String }
        struct Comment: Decodable {
            let id: String
            let author: Actor?
            let body: String
            let createdAt: Date
            let url: String?
            let state: String
        }
        let id: String
        let path: String
        let line: Int?
        let startLine: Int?
        let originalLine: Int?
        let diffSide: String
        let isOutdated: Bool
        let isResolved: Bool
        let comments: Nodes
    }
}

/// What's needed to write a review: the PR's node ID and the viewer's pending review, if any.
public struct ReviewContext: Hashable, Sendable {
    public let pullRequestID: String
    public var pendingReviewID: String?

    static let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) { id reviews(states: PENDING, first: 1) { nodes { id } } }
          }
        }
        """

    static func decode(from data: Data) throws -> ReviewContext {
        struct Response: Decodable {
            struct Payload: Decodable { let repository: Repository? }
            struct Repository: Decodable { let pullRequest: PR? }
            struct PR: Decodable {
                struct Reviews: Decodable { let nodes: [Node?] }
                struct Node: Decodable { let id: String }
                let id: String
                let reviews: Reviews
            }
            let data: Payload
        }
        guard let pr = try JSONDecoder().decode(Response.self, from: data).data.repository?.pullRequest else {
            throw PullRequestOverview.NotFound()
        }
        return ReviewContext(pullRequestID: pr.id, pendingReviewID: pr.reviews.nodes.compactMap(\.self).first?.id)
    }
}

/// How a review is submitted.
public enum ReviewEvent: String, CaseIterable, Identifiable, Sendable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"

    public var id: Self { self }
    public var title: String {
        switch self {
        case .comment: "Comment"
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        }
    }
}
