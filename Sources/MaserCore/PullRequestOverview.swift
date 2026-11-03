// The model behind a PR's Overview tab, and the GraphQL query that fills it.
//
// `PullRequestOverview` gathers what GitHub shows on a PR's conversation page: metadata, description, issue comments,
// reviews, reviewer verdicts and CI checks. The GraphQL extension holds the query, the raw response shapes, and the
// mapping from those shapes into the public model.

import Foundation

/// Everything on a PR's "conversation" page: metadata, description, discussion, review and CI status.
public struct PullRequestOverview: Hashable, Sendable {
    /// Whether the PR is open, closed without merging, or merged.
    public enum State: String, Sendable { case open = "OPEN", closed = "CLOSED", merged = "MERGED" }

    /// Whether the PR can merge cleanly into its base, as GitHub's `MergeableState` reports it.
    ///
    /// GitHub computes this lazily, so a freshly loaded PR is often `unknown` until GitHub finishes the check.
    public enum Mergeable: String, Sendable {
        case mergeable = "MERGEABLE", conflicting = "CONFLICTING", unknown = "UNKNOWN"
    }

    /// GitHub's `MergeStateStatus`: what, if anything, stands between the PR and merging.
    public enum MergeState: String, Sendable {
        case behind = "BEHIND", blocked = "BLOCKED", clean = "CLEAN", dirty = "DIRTY"
        case draft = "DRAFT", hasHooks = "HAS_HOOKS", unknown = "UNKNOWN", unstable = "UNSTABLE"
    }

    /// The review verdict branch protection uses, as GitHub's `PullRequestReviewDecision` reports it.
    public enum ReviewDecision: String, Sendable {
        case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", reviewRequired = "REVIEW_REQUIRED"
    }

    /// A label applied to the PR.
    public struct IssueLabel: Hashable, Sendable {
        /// The label's display name.
        public let name: String
        /// Hex RGB without `#`.
        public let color: String
    }

    /// The PR number within its repository.
    public let number: Int
    /// The PR's title.
    public let title: String
    /// The PR's page on GitHub.
    public let url: URL
    /// Open, closed or merged.
    public let state: State
    /// Whether the PR is a draft.
    public let isDraft: Bool
    /// The author's login, or `"ghost"` if the account was deleted.
    public let author: String
    /// When the PR was opened.
    public let createdAt: Date
    /// The branch the PR merges into.
    public let baseRef: String
    /// The branch the PR merges from.
    public let headRef: String
    /// Lines added across the whole PR.
    public let additions: Int
    /// Lines deleted across the whole PR.
    public let deletions: Int
    /// Number of files the PR changes.
    public let changedFiles: Int
    /// Description rendered to HTML by GitHub.
    public let bodyHTML: String
    /// The description's Markdown source.
    public let body: String
    /// Whether the PR merges cleanly.
    public let mergeable: Mergeable
    /// What is blocking the merge, if anything.
    public let mergeState: MergeState
    /// The overall review verdict, or `nil` when the repository doesn't require reviews.
    public let reviewDecision: ReviewDecision?
    /// Labels applied to the PR.
    public let labels: [IssueLabel]
    /// Users (by login) and teams (by name) whose review is still requested.
    public let requestedReviewers: [String]
    /// The latest 100 conversation comments, oldest first.
    public let comments: [IssueComment]
    /// The latest 100 submitted reviews; the viewer's pending draft review is left out.
    public let reviews: [Review]
    /// Checks on the head commit, most urgent first.
    public let checks: [Check]
    /// The combined state of all checks on the head commit, or `nil` if it has none.
    public let checksRollup: CheckState?

    /// Comments and reviews in chronological order.
    ///
    /// Bodyless "commented" reviews are omitted: they only wrap inline comments, which belong to the Files view.
    public var timeline: [TimelineItem] {
        let commentItems = comments.map {
            TimelineItem(
                id: $0.id, kind: .comment, author: $0.author, body: $0.body, bodyHTML: $0.bodyHTML, date: $0.createdAt,
                url: $0.url)
        }
        let reviewItems =
            reviews
            .filter { !($0.state == .commented && $0.bodyHTML.isEmpty) }
            .map {
                TimelineItem(
                    id: $0.id, kind: .review($0.state), author: $0.author, body: $0.body, bodyHTML: $0.bodyHTML,
                    date: $0.submittedAt, url: $0.url)
            }
        return (commentItems + reviewItems).sorted { $0.date < $1.date }
    }

    /// Each reviewer's current verdict.
    ///
    /// That is their latest approve, request-changes or dismissed review, or "commented" if that's all they've done.
    /// Reviewers are ordered by their first review.
    public var reviewerStatuses: [ReviewerStatus] {
        var order: [String] = []
        var latest: [String: Review.State] = [:]
        for review in reviews.sorted(by: { $0.submittedAt < $1.submittedAt }) {
            if latest[review.author] == nil { order.append(review.author) }
            // A later plain comment doesn't undo an earlier approval or change request.
            if review.state != .commented || latest[review.author] == nil {
                latest[review.author] = review.state
            }
        }
        // Every author in `order` was given a `latest` entry in the same loop iteration.
        return order.map { ReviewerStatus(author: $0, state: latest[$0]!) }
    }
}

/// A comment in a PR's conversation, as opposed to an inline review comment on the diff.
public struct IssueComment: Identifiable, Hashable, Sendable {
    /// GitHub's GraphQL node ID.
    public let id: String
    /// The commenter's login, or `"ghost"` if the account was deleted.
    public let author: String
    /// The comment's Markdown source.
    public let body: String
    /// The comment rendered to HTML by GitHub.
    public let bodyHTML: String
    /// When the comment was posted.
    public let createdAt: Date
    /// The comment's permalink on GitHub.
    public let url: URL
}

/// A submitted review on the PR.
public struct Review: Identifiable, Hashable, Sendable {
    /// The verdict a review carries.
    public enum State: String, Sendable {
        case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED"
        case commented = "COMMENTED", dismissed = "DISMISSED"
    }

    /// GitHub's GraphQL node ID.
    public let id: String
    /// The reviewer's login, or `"ghost"` if the account was deleted.
    public let author: String
    /// The review's verdict.
    public let state: State
    /// The review summary's Markdown source; empty when the reviewer left none.
    public let body: String
    /// The review summary rendered to HTML by GitHub.
    public let bodyHTML: String
    /// When the review was submitted.
    public let submittedAt: Date
    /// The review's permalink on GitHub.
    public let url: URL
}

/// One reviewer's current verdict on the PR.
public struct ReviewerStatus: Hashable, Sendable {
    /// The reviewer's login.
    public let author: String
    /// Their verdict; see `PullRequestOverview.reviewerStatuses` for how it's chosen.
    public let state: Review.State
}

/// An entry in the Overview tab's conversation: a comment or a review.
public struct TimelineItem: Identifiable, Hashable, Sendable {
    /// What kind of entry this is.
    public enum Kind: Hashable, Sendable {
        /// A conversation comment.
        case comment
        /// A review with the given verdict.
        case review(Review.State)
    }

    /// The underlying comment's or review's GraphQL node ID.
    public let id: String
    /// Whether this is a comment or a review.
    public let kind: Kind
    /// The author's login.
    public let author: String
    /// Markdown source, for quoting.
    public let body: String
    /// The body rendered to HTML by GitHub.
    public let bodyHTML: String
    /// When the comment was posted or the review submitted.
    public let date: Date
    /// The entry's permalink on GitHub.
    public let url: URL
}

/// Outcome of a CI check, ordered most to least urgent.
public enum CheckState: Int, Comparable, Hashable, Sendable {
    case failure, pending, cancelled, neutral, success, skipped

    /// Orders states by urgency, so `failure` sorts first.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Maps a GraphQL `StatusState`, used by rollups and commit statuses.
    ///
    /// - Parameter statusState: The raw `StatusState` value. Anything unrecognized counts as pending.
    init(statusState: String) {
        switch statusState {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        default: self = .pending  // PENDING, EXPECTED
        }
    }

    /// Maps a check run's `CheckStatusState` and `CheckConclusionState`.
    ///
    /// - Parameters:
    ///   - status: The run's status. Anything but `COMPLETED` counts as pending.
    ///   - conclusion: The completed run's conclusion. Unrecognized or missing values count as failure.
    init(status: String?, conclusion: String?) {
        guard status == "COMPLETED" else { self = .pending; return }
        switch conclusion {
        case "SUCCESS": self = .success
        case "SKIPPED": self = .skipped
        case "CANCELLED": self = .cancelled
        case "NEUTRAL", "STALE": self = .neutral
        default: self = .failure  // FAILURE, TIMED_OUT, ACTION_REQUIRED, STARTUP_FAILURE
        }
    }
}

/// A CI check run or commit status on the PR's head commit.
public struct Check: Identifiable, Hashable, Sendable {
    /// The check's position in GitHub's response; stable only within one load.
    public let id: Int
    /// The check run's name or the status's context.
    public let name: String
    /// Workflow (for GitHub Actions) or status description.
    public let detail: String?
    /// The check's outcome.
    public let state: CheckState
    /// Where to see the check's details, if GitHub gave a link.
    public let url: URL?
}

// MARK: - GraphQL

extension PullRequestOverview {
    /// The GraphQL query for everything the Overview tab shows.
    ///
    /// Takes `$owner`, `$name` and `$number`. Lists are capped (the latest 100 comments and reviews, the first 100
    /// checks, 50 labels and review requests) and not paginated.
    static let query = """
        query($owner: String!, $name: String!, $number: Int!) {
          repository(owner: $owner, name: $name) {
            pullRequest(number: $number) {
              number title url state isDraft createdAt
              author { login }
              baseRefName headRefName additions deletions changedFiles
              body bodyHTML
              mergeable mergeStateStatus reviewDecision
              labels(first: 50) { nodes { name color } }
              reviewRequests(first: 50) { nodes { requestedReviewer { ... on User { login } ... on Team { name } } } }
              comments(last: 100) { nodes { id author { login } body bodyHTML createdAt url } }
              reviews(last: 100) { nodes { id author { login } state body bodyHTML submittedAt url } }
              commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) { nodes {
                __typename
                ... on CheckRun { name status conclusion detailsUrl checkSuite { workflowRun { workflow { name } } } }
                ... on StatusContext { context state targetUrl description }
              } } } } } }
            }
          }
        }
        """

    /// Thrown when the response has no such repository or pull request.
    struct NotFound: Error, LocalizedError {
        var errorDescription: String? { "Pull request not found." }
    }

    /// Decodes the JSON response to `query`.
    ///
    /// - Parameter data: The raw response body from `gh api graphql`.
    /// - Returns: The decoded overview.
    /// - Throws: `NotFound` if the repository or PR is missing, or a `DecodingError` if the JSON has the wrong shape.
    static func decode(from data: Data) throws -> PullRequestOverview {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try decoder.decode(Response.self, from: data).data.repository?.pullRequest else {
            throw NotFound()
        }
        return PullRequestOverview(raw)
    }

    /// Builds the overview from the raw GraphQL pull request.
    ///
    /// Unknown enum values fall back to a neutral default (`open`, `unknown`), deleted accounts become `"ghost"`,
    /// and the viewer's pending review is dropped.
    ///
    /// - Parameter raw: The decoded `pullRequest` object.
    init(_ raw: RawPR) {
        number = raw.number
        title = raw.title
        url = raw.url
        state = State(rawValue: raw.state) ?? .open
        isDraft = raw.isDraft
        author = raw.author?.login ?? "ghost"
        createdAt = raw.createdAt
        baseRef = raw.baseRefName
        headRef = raw.headRefName
        additions = raw.additions
        deletions = raw.deletions
        changedFiles = raw.changedFiles
        bodyHTML = raw.bodyHTML
        body = raw.body ?? ""
        mergeable = Mergeable(rawValue: raw.mergeable) ?? .unknown
        mergeState = MergeState(rawValue: raw.mergeStateStatus) ?? .unknown
        reviewDecision = raw.reviewDecision.flatMap(ReviewDecision.init(rawValue:))
        labels = raw.labels.values.map { IssueLabel(name: $0.name, color: $0.color) }
        requestedReviewers = raw.reviewRequests.values.compactMap { $0.requestedReviewer?.login ?? $0.requestedReviewer?.name }
        comments = raw.comments.values.map {
            IssueComment(
                id: $0.id, author: $0.author?.login ?? "ghost", body: $0.body ?? "", bodyHTML: $0.bodyHTML,
                createdAt: $0.createdAt, url: $0.url)
        }
        reviews = raw.reviews.values.compactMap { review in
            // Pending reviews (the viewer's unsubmitted draft) have no submittedAt.
            guard let submittedAt = review.submittedAt, let state = Review.State(rawValue: review.state) else { return nil }
            return Review(
                id: review.id, author: review.author?.login ?? "ghost", state: state,
                body: review.body ?? "", bodyHTML: review.bodyHTML, submittedAt: submittedAt, url: review.url)
        }

        let rollup = raw.commits.values.first?.commit.statusCheckRollup
        checksRollup = rollup.map { CheckState(statusState: $0.state) }
        checks = (rollup?.contexts.values ?? []).enumerated().map { index, context in
            if context.typename == "StatusContext" {
                Check(
                    id: index, name: context.context ?? "status", detail: context.description,
                    state: CheckState(statusState: context.state ?? ""), url: context.targetUrl.flatMap(URL.init(string:)))
            } else {
                Check(
                    id: index, name: context.name ?? "check", detail: context.checkSuite?.workflowRun?.workflow?.name,
                    state: CheckState(status: context.status, conclusion: context.conclusion),
                    url: context.detailsUrl.flatMap(URL.init(string:)))
            }
        }
        .sorted { ($0.state, $0.name.lowercased()) < ($1.state, $1.name.lowercased()) }
    }

    /// The top level of the GraphQL response.
    struct Response: Decodable {
        /// The response's `data` object.
        struct Payload: Decodable { let repository: Repository? }
        /// The `repository` object; `nil` when the repository doesn't exist or isn't visible.
        struct Repository: Decodable { let pullRequest: RawPR? }
        let data: Payload
    }

    /// GraphQL connection; nodes may be null.
    struct Nodes<Node: Decodable>: Decodable {
        let nodes: [Node?]
        /// The non-null nodes.
        var values: [Node] { nodes.compactMap(\.self) }
    }

    /// A GitHub user or bot, identified by login.
    struct Actor: Decodable { let login: String }

    /// The `pullRequest` object as GraphQL returns it.
    struct RawPR: Decodable {
        let number: Int
        let title: String
        let url: URL
        let state: String
        let isDraft: Bool
        let createdAt: Date
        let author: Actor?
        let baseRefName: String
        let headRefName: String
        let additions: Int
        let deletions: Int
        let changedFiles: Int
        let body: String?
        let bodyHTML: String
        let mergeable: String
        let mergeStateStatus: String
        let reviewDecision: String?
        let labels: Nodes<RawLabel>
        let reviewRequests: Nodes<RawReviewRequest>
        let comments: Nodes<RawComment>
        let reviews: Nodes<RawReview>
        let commits: Nodes<RawCommitNode>
    }

    /// A label as GraphQL returns it.
    struct RawLabel: Decodable { let name: String; let color: String }

    /// A pending review request as GraphQL returns it.
    struct RawReviewRequest: Decodable {
        /// The requested reviewer: a user (with `login`) or a team (with `name`).
        struct Reviewer: Decodable { let login: String?; let name: String? }
        let requestedReviewer: Reviewer?
    }

    /// A conversation comment as GraphQL returns it.
    struct RawComment: Decodable {
        let id: String
        let author: Actor?
        let body: String?
        let bodyHTML: String
        let createdAt: Date
        let url: URL
    }

    /// A review as GraphQL returns it.
    struct RawReview: Decodable {
        let id: String
        let author: Actor?
        let state: String
        let body: String?
        let bodyHTML: String
        /// `nil` for the viewer's pending review.
        let submittedAt: Date?
        let url: URL
    }

    /// A commit node from the PR's `commits` connection.
    struct RawCommitNode: Decodable {
        /// The commit, reduced to its CI rollup.
        struct Commit: Decodable { let statusCheckRollup: Rollup? }
        /// The combined CI state and its individual checks.
        struct Rollup: Decodable {
            let state: String
            let contexts: Nodes<RawContext>
        }
        let commit: Commit
    }

    /// One rollup context: either a `CheckRun` or a `StatusContext`, flattened into one shape.
    ///
    /// Only the fields for the type named by `typename` are set.
    struct RawContext: Decodable {
        /// The check suite a check run belongs to, reduced to its workflow name.
        struct CheckSuite: Decodable {
            /// The GitHub Actions run behind the suite, if any.
            struct WorkflowRun: Decodable {
                /// The workflow the run belongs to.
                struct Workflow: Decodable { let name: String }
                let workflow: Workflow?
            }
            let workflowRun: WorkflowRun?
        }

        /// `CheckRun` or `StatusContext`.
        let typename: String
        // CheckRun
        let name: String?
        let status: String?
        let conclusion: String?
        let detailsUrl: String?
        let checkSuite: CheckSuite?
        // StatusContext
        let context: String?
        let state: String?
        let targetUrl: String?
        let description: String?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case name, status, conclusion, detailsUrl, checkSuite, context, state, targetUrl, description
        }
    }
}
