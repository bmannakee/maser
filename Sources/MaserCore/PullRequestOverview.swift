import Foundation

/// Everything on a PR's "conversation" page: metadata, description, discussion, review and CI status.
public struct PullRequestOverview: Hashable, Sendable {
    public enum State: String, Sendable { case open = "OPEN", closed = "CLOSED", merged = "MERGED" }

    public enum Mergeable: String, Sendable {
        case mergeable = "MERGEABLE", conflicting = "CONFLICTING", unknown = "UNKNOWN"
    }

    /// GitHub's `MergeStateStatus`.
    public enum MergeState: String, Sendable {
        case behind = "BEHIND", blocked = "BLOCKED", clean = "CLEAN", dirty = "DIRTY"
        case draft = "DRAFT", hasHooks = "HAS_HOOKS", unknown = "UNKNOWN", unstable = "UNSTABLE"
    }

    public enum ReviewDecision: String, Sendable {
        case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", reviewRequired = "REVIEW_REQUIRED"
    }

    public struct IssueLabel: Hashable, Sendable {
        public let name: String
        /// Hex RGB without `#`.
        public let color: String
    }

    public let number: Int
    public let title: String
    public let url: URL
    public let state: State
    public let isDraft: Bool
    public let author: String
    public let createdAt: Date
    public let baseRef: String
    public let headRef: String
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    /// Description rendered to HTML by GitHub.
    public let bodyHTML: String
    /// The description's Markdown source.
    public let body: String
    public let mergeable: Mergeable
    public let mergeState: MergeState
    public let reviewDecision: ReviewDecision?
    public let labels: [IssueLabel]
    public let requestedReviewers: [String]
    public let comments: [IssueComment]
    public let reviews: [Review]
    /// Checks on the head commit, most urgent first.
    public let checks: [Check]
    public let checksRollup: CheckState?

    /// Comments and reviews in chronological order. Bodyless "commented" reviews are omitted:
    /// they only wrap inline comments, which belong to the Files view.
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

    /// Each reviewer's current verdict: their latest approve/request-changes/dismissed review,
    /// or "commented" if that's all they've done. Ordered by first review.
    public var reviewerStatuses: [ReviewerStatus] {
        var order: [String] = []
        var latest: [String: Review.State] = [:]
        for review in reviews.sorted(by: { $0.submittedAt < $1.submittedAt }) {
            if latest[review.author] == nil { order.append(review.author) }
            if review.state != .commented || latest[review.author] == nil {
                latest[review.author] = review.state
            }
        }
        return order.map { ReviewerStatus(author: $0, state: latest[$0]!) }
    }
}

public struct IssueComment: Identifiable, Hashable, Sendable {
    public let id: String
    public let author: String
    public let body: String
    public let bodyHTML: String
    public let createdAt: Date
    public let url: URL
}

public struct Review: Identifiable, Hashable, Sendable {
    public enum State: String, Sendable {
        case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED"
        case commented = "COMMENTED", dismissed = "DISMISSED"
    }

    public let id: String
    public let author: String
    public let state: State
    public let body: String
    public let bodyHTML: String
    public let submittedAt: Date
    public let url: URL
}

public struct ReviewerStatus: Hashable, Sendable {
    public let author: String
    public let state: Review.State
}

public struct TimelineItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case comment
        case review(Review.State)
    }

    public let id: String
    public let kind: Kind
    public let author: String
    /// Markdown source, for quoting.
    public let body: String
    public let bodyHTML: String
    public let date: Date
    public let url: URL
}

/// Outcome of a CI check, ordered most to least urgent.
public enum CheckState: Int, Comparable, Hashable, Sendable {
    case failure, pending, cancelled, neutral, success, skipped

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// `StatusState` (rollups and commit statuses).
    init(statusState: String) {
        switch statusState {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR": self = .failure
        default: self = .pending  // PENDING, EXPECTED
        }
    }

    /// A check run's `CheckStatusState` + `CheckConclusionState`.
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

public struct Check: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String
    /// Workflow (for GitHub Actions) or status description.
    public let detail: String?
    public let state: CheckState
    public let url: URL?
}

// MARK: - GraphQL

extension PullRequestOverview {
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

    struct NotFound: Error, LocalizedError {
        var errorDescription: String? { "Pull request not found." }
    }

    static func decode(from data: Data) throws -> PullRequestOverview {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try decoder.decode(Response.self, from: data).data.repository?.pullRequest else {
            throw NotFound()
        }
        return PullRequestOverview(raw)
    }

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

    struct Response: Decodable {
        struct Payload: Decodable { let repository: Repository? }
        struct Repository: Decodable { let pullRequest: RawPR? }
        let data: Payload
    }

    /// GraphQL connection; nodes may be null.
    struct Nodes<Node: Decodable>: Decodable {
        let nodes: [Node?]
        var values: [Node] { nodes.compactMap(\.self) }
    }

    struct Actor: Decodable { let login: String }

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

    struct RawLabel: Decodable { let name: String; let color: String }

    struct RawReviewRequest: Decodable {
        struct Reviewer: Decodable { let login: String?; let name: String? }
        let requestedReviewer: Reviewer?
    }

    struct RawComment: Decodable {
        let id: String
        let author: Actor?
        let body: String?
        let bodyHTML: String
        let createdAt: Date
        let url: URL
    }

    struct RawReview: Decodable {
        let id: String
        let author: Actor?
        let state: String
        let body: String?
        let bodyHTML: String
        let submittedAt: Date?
        let url: URL
    }

    struct RawCommitNode: Decodable {
        struct Commit: Decodable { let statusCheckRollup: Rollup? }
        struct Rollup: Decodable {
            let state: String
            let contexts: Nodes<RawContext>
        }
        let commit: Commit
    }

    struct RawContext: Decodable {
        struct CheckSuite: Decodable {
            struct WorkflowRun: Decodable {
                struct Workflow: Decodable { let name: String }
                let workflow: Workflow?
            }
            let workflowRun: WorkflowRun?
        }

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
