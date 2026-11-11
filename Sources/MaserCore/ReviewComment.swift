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
    /// The side of the diff `startLine` is on, for a multi-line thread.
    public let startSide: DiffSide?
    /// Whether the code under the thread has changed since it was written, or the thread no longer maps to a line.
    public let isOutdated: Bool
    /// Whether someone has marked the thread resolved.
    public let isResolved: Bool
    /// The thread's comments, oldest first; never empty.
    public let comments: [ReviewComment]
    /// Whether GitHub has more comments in the thread than `comments` holds, because the query only fetched its first
    /// page.
    let hasMoreComments: Bool

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
        return ReviewThread(copying: self, comments: posted, hasMoreComments: hasMoreComments)
    }

    /// Returns the thread with all its comments, as fetched by `commentsQuery`.
    ///
    /// - Parameter comments: Every comment in the thread, oldest first. If empty, the thread is returned unchanged.
    /// - Returns: The thread with `comments` and `hasMoreComments` cleared.
    func replacingComments(_ comments: [ReviewComment]) -> ReviewThread {
        guard !comments.isEmpty else { return self }
        return ReviewThread(copying: self, comments: comments, hasMoreComments: false)
    }

    /// Creates a copy of `thread` with `comments` in place of its own.
    ///
    /// The caller must pass a non-empty `comments`, which `root` relies on.
    private init(copying thread: ReviewThread, comments: [ReviewComment], hasMoreComments: Bool) {
        id = thread.id
        path = thread.path
        line = thread.line
        startLine = thread.startLine
        startSide = thread.startSide
        originalLine = thread.originalLine
        side = thread.side
        isOutdated = thread.isOutdated
        isResolved = thread.isResolved
        self.comments = comments
        self.hasMoreComments = hasMoreComments
    }

    /// The `--jq` filter that turns each page of output from `query` into one compact JSON thread object per line.
    static let jqFilter = ".data.repository.pullRequest.reviewThreads.nodes[]"

    /// The GraphQL query for a PR's review threads, paginated by `gh api graphql --paginate` through `$endCursor`.
    ///
    /// Each thread fetches its first 100 comments, and their `totalCount`; `commentsQuery` gets the rest.
    static let query = """
        query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              reviewThreads(first: 100, after: $endCursor) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id path line startLine originalLine diffSide startDiffSide isOutdated isResolved
                  comments(first: 100) { totalCount nodes { \(commentFields) } }
                }
              }
            }
          }
        }
        """

    /// The fields fetched for each comment.
    private static let commentFields = "id author { login } body createdAt url state"

    /// The GraphQL query for all of one thread's comments, paginated through `$endCursor`; takes the thread's `$thread`
    /// ID.
    static let commentsQuery = """
        query($thread: ID!, $endCursor: String) {
          node(id: $thread) {
            ... on PullRequestReviewThread {
              comments(first: 100, after: $endCursor) {
                pageInfo { hasNextPage endCursor }
                nodes { \(commentFields) }
              }
            }
          }
        }
        """

    /// The `--jq` filter that turns each page of `commentsQuery` output into one JSON comment object per line.
    static let commentsJQFilter = ".data.node.comments.nodes[]"

    /// Decodes the line-per-comment output of `commentsQuery` filtered through `commentsJQFilter`.
    ///
    /// - Parameter data: Newline-separated JSON comment objects.
    /// - Returns: The comments, in the order GitHub returned them (oldest first).
    /// - Throws: A `DecodingError` if a line isn't a valid comment object.
    static func decodeCommentLines(from data: Data) throws -> [ReviewComment] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: UInt8(ascii: "\n")).map {
            ReviewComment(try decoder.decode(Raw.Comment.self, from: Data($0)))
        }
    }

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
        let comments = raw.comments.nodes.compactMap(\.self).map(ReviewComment.init)
        guard !comments.isEmpty else { return nil }
        hasMoreComments = (raw.comments.totalCount ?? 0) > raw.comments.nodes.count
        id = raw.id
        path = raw.path
        line = raw.line
        startLine = raw.startLine
        originalLine = raw.originalLine
        side = DiffSide(rawValue: raw.diffSide) ?? .right
        startSide = raw.startDiffSide.flatMap(DiffSide.init(rawValue:))
        isOutdated = raw.isOutdated || raw.line == nil
        isResolved = raw.isResolved
        self.comments = comments
    }

    /// A review thread node exactly as the GraphQL API returns it.
    fileprivate struct Raw: Decodable {
        /// A GraphQL connection's `nodes`, which may contain `null`s, and how many there are in all.
        struct Nodes: Decodable {
            let totalCount: Int?
            let nodes: [Comment?]
        }
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
        /// `nil` for single-line threads.
        let startDiffSide: String?
        let isOutdated: Bool
        let isResolved: Bool
        let comments: Nodes
    }
}

extension ReviewComment {
    /// Creates a comment from its decoded GraphQL node; a missing author becomes `"ghost"`.
    fileprivate init(_ raw: ReviewThread.Raw.Comment) {
        self.init(
            id: raw.id,
            author: raw.author?.login ?? "ghost",
            body: raw.body,
            createdAt: raw.createdAt,
            url: raw.url.flatMap(URL.init(string:)),
            isPending: raw.state == "PENDING"
        )
    }
}

/// What's needed to write a review: the PR's node ID and the viewer's pending review, if any.
///
/// It also has the PR's head commit, which full-file views read files at.
public struct ReviewContext: Hashable, Sendable {
    /// The pull request's GraphQL node ID.
    public let pullRequestID: String
    /// The node ID of the viewer's pending review; `nil` when they don't have one.
    public var pendingReviewID: String?
    /// The SHA of the PR's head commit.
    public let headCommitID: String
    /// The login of the account `gh` is signed in to on the PR's host, which anything posted appears under.
    public var viewerLogin: String?

    /// The GraphQL query for the PR's node ID, head commit, the viewer's login and their pending review.
    ///
    /// GitHub returns only the viewer's own pending review, since nobody else's is visible to them.
    static let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          viewer { login }
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) { id headRefOid reviews(states: PENDING, first: 1) { nodes { id } } }
          }
        }
        """

    /// Checks that the PR's head is still the commit the user's diff was loaded at.
    ///
    /// GitHub places a new review thread on the PR's current head, whatever commit its review is pinned to, so a line
    /// number from an older diff could land on a different line. Call this on a freshly fetched context just before
    /// posting.
    ///
    /// - Parameter seen: The head commit of the diff the user saw.
    /// - Throws: `GitHubCLIError.headMoved` if the head is a different commit.
    public func requireHead(_ seen: String) throws {
        guard headCommitID == seen else { throw GitHubCLIError.headMoved(seen: seen, current: headCommitID) }
    }

    /// Checks that `gh` is still signed in to the account the user was shown.
    ///
    /// Someone may switch accounts with `gh auth switch` while Maser is open, or Maser may not have shown one yet.
    /// Call this on a freshly fetched context just before posting.
    ///
    /// - Parameter shown: The login the user was shown, or nil if none was.
    /// - Throws: `GitHubCLIError.accountChanged` if the account isn't the one shown.
    public func requireViewer(_ shown: String?) throws {
        guard let viewerLogin, viewerLogin == shown else {
            throw GitHubCLIError.accountChanged(shown: shown, current: viewerLogin)
        }
    }

    /// Decodes the `gh api graphql` response to `query`.
    ///
    /// - Parameter data: The response's JSON.
    /// - Returns: The PR's node ID and the viewer's pending review ID, if any.
    /// - Throws: `PullRequestOverview.NotFound` if the repository or pull request is missing from the response, or a
    ///   `DecodingError` if the JSON doesn't have the expected shape.
    static func decode(from data: Data) throws -> ReviewContext {
        /// The response's shape, keeping only the fields `ReviewContext` uses.
        struct Response: Decodable {
            struct Payload: Decodable {
                let viewer: Viewer?
                let repository: Repository?
            }
            struct Viewer: Decodable { let login: String }
            struct Repository: Decodable { let pullRequest: PR? }
            struct PR: Decodable {
                struct Reviews: Decodable { let nodes: [Node?] }
                struct Node: Decodable { let id: String }
                let id: String
                let headRefOid: String
                let reviews: Reviews
            }
            let data: Payload
        }
        let payload = try JSONDecoder().decode(Response.self, from: data).data
        guard let pr = payload.repository?.pullRequest else { throw PullRequestOverview.NotFound() }
        return ReviewContext(
            pullRequestID: pr.id, pendingReviewID: pr.reviews.nodes.compactMap(\.self).first?.id,
            headCommitID: pr.headRefOid, viewerLogin: payload.viewer?.login)
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
