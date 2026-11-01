// Inline review threads and the models for writing a review.
//
// `ReviewThread` and `ReviewComment` model the comment threads attached to diff lines, decoded from the GraphQL
// `reviewThreads` query that `GitHubCLI.reviewThreads(for:)` runs. `ReviewContext` and `ReviewEvent` carry what the
// review-writing calls in `GitHubCLI+Reviews.swift` need: the PR's node ID, the viewer's pending review and the verdict.

import Foundation

/// A comment in an inline review thread.
public struct ReviewComment: Identifiable, Hashable, Sendable {
    /// The comment's GraphQL node ID, used to delete it while it's pending.
    public let id: String
    /// The author's login, or `"ghost"` when the account has been deleted.
    public let author: String
    /// The comment's Markdown source.
    public let body: String
    /// When the comment was created.
    public let createdAt: Date
    /// The comment's permalink on GitHub; `nil` when GitHub doesn't return one, as for some pending comments.
    public let url: URL?
    /// Whether the comment belongs to the viewer's unsubmitted review, and so is visible only to them.
    public let isPending: Bool
}

/// An inline review thread on a PR's diff.
///
/// Decoded from GraphQL `reviewThreads`, which, unlike the REST API, includes the viewer's pending comments along with
/// their side and line range. A thread always has at least one comment.
public struct ReviewThread: Identifiable, Hashable, Sendable {
    /// The thread's GraphQL node ID, used to reply to it.
    public let id: String
    /// The path of the file the thread is on, relative to the repository root.
    public let path: String
    /// The line in the current diff (the last line, for a range); `nil` when the thread is outdated.
    public let line: Int?
    /// The first line of a multi-line thread; `nil` for a single-line thread.
    public let startLine: Int?
    /// The line the thread was first placed on, in the diff it was written against.
    public let originalLine: Int?
    /// The side of the diff `line` refers to.
    public let side: DiffSide
    /// Whether the code under the thread has changed since it was written, or the thread no longer maps to a line.
    public let isOutdated: Bool
    /// Whether someone has marked the thread resolved.
    public let isResolved: Bool
    /// The thread's comments, oldest first; never empty.
    public let comments: [ReviewComment]

    // Safe: every initializer guarantees `comments` is non-empty.
    /// The comment that started the thread.
    public var root: ReviewComment { comments[0] }
    /// Whether the thread itself is a draft (as opposed to a draft reply on a posted thread).
    public var isPending: Bool { root.isPending }
    /// Whether any comment in the thread, root or reply, is in the viewer's pending review.
    public var hasPendingComments: Bool { comments.contains(where: \.isPending) }

    /// Returns the thread without the viewer's draft comments.
    ///
    /// GitHub takes a few seconds to reflect a discarded review, so the app applies this locally to hide the drafts at
    /// once.
    ///
    /// - Returns: The thread with only its posted comments, or `nil` if nothing is left because it was a draft thread.
    public func removingPendingComments() -> ReviewThread? {
        let posted = comments.filter { !$0.isPending }
        guard !posted.isEmpty else { return nil }
        return ReviewThread(copying: self, comments: posted)
    }

    /// Creates a copy of `thread` with `comments` in place of its own.
    ///
    /// The caller must pass a non-empty `comments`, which `root` relies on.
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

    /// The `--jq` filter that turns each page of output from `query` into one compact JSON thread object per line.
    static let jqFilter = ".data.repository.pullRequest.reviewThreads.nodes[]"

    /// The GraphQL query for a PR's review threads, paginated by `gh api graphql --paginate` through `$endCursor`.
    ///
    /// Each thread fetches its first 100 comments only.
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

    /// Decodes the line-per-thread output of `query` filtered through `jqFilter`.
    ///
    /// Threads with no comments are dropped. The rest are sorted by current line, with outdated threads (no line) last,
    /// then by original line and the root comment's creation time. The sort ignores `path`.
    ///
    /// - Parameter data: Newline-separated JSON thread objects; empty data gives no threads.
    /// - Returns: The decoded threads in display order.
    /// - Throws: A `DecodingError` if a line isn't a valid thread object.
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

    /// Creates a thread from its decoded GraphQL node, or fails if the node has no comments.
    ///
    /// A missing author becomes `"ghost"`, an unknown side becomes `.right`, and a thread with no current line is
    /// treated as outdated even if GitHub doesn't flag it.
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

    /// A review thread node exactly as the GraphQL API returns it.
    private struct Raw: Decodable {
        /// A GraphQL connection's `nodes`, which may contain `null`s.
        struct Nodes: Decodable { let nodes: [Comment?] }
        /// A comment's author; `null` in the JSON when the account was deleted.
        struct Actor: Decodable { let login: String }
        /// A comment node, with its `state` as a raw `PullRequestReviewCommentState` such as `"PENDING"`.
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
    /// The pull request's GraphQL node ID.
    public let pullRequestID: String
    /// The node ID of the viewer's pending review; `nil` when they don't have one.
    public var pendingReviewID: String?

    /// The GraphQL query for the PR's node ID and the viewer's pending review.
    ///
    /// GitHub returns only the viewer's own pending review, since nobody else's is visible to them.
    static let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) { id reviews(states: PENDING, first: 1) { nodes { id } } }
          }
        }
        """

    /// Decodes the `gh api graphql` response to `query`.
    ///
    /// - Parameter data: The response's JSON.
    /// - Returns: The PR's node ID and the viewer's pending review ID, if any.
    /// - Throws: `PullRequestOverview.NotFound` if the repository or pull request is missing from the response, or a
    ///   `DecodingError` if the JSON doesn't have the expected shape.
    static func decode(from data: Data) throws -> ReviewContext {
        /// The response's shape, keeping only the fields `ReviewContext` uses.
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

/// The verdict a review is submitted with; raw values are GraphQL `PullRequestReviewEvent` names.
public enum ReviewEvent: String, CaseIterable, Identifiable, Sendable {
    /// Feedback without approving or blocking.
    case comment = "COMMENT"
    /// Approves the changes.
    case approve = "APPROVE"
    /// Asks for changes before the PR can merge.
    case requestChanges = "REQUEST_CHANGES"

    /// The event itself, so it can drive a SwiftUI `Picker` or `ForEach`.
    public var id: Self { self }
    /// The event's user-facing name, as shown in the submit UI.
    public var title: String {
        switch self {
        case .comment: "Comment"
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        }
    }
}
