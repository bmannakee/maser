import Foundation

/// Inline review threads and writing reviews, through GitHub's GraphQL API.
extension GitHubCLI {
    /// All inline review threads (every page), including the viewer's pending comments.
    @concurrent
    public func reviewThreads(for pr: PullRequest) async throws -> [ReviewThread] {
        let data = try await graphQL(
            ReviewThread.query, host: pr.host, paginate: true, jq: ReviewThread.jqFilter,
            strings: repoVariables(pr), ints: ["number": pr.number])
        return try ReviewThread.decodeLines(from: data)
    }

    /// The PR's node ID and the viewer's pending review, if they have one.
    @concurrent
    public func reviewContext(for pr: PullRequest) async throws -> ReviewContext {
        let data = try await graphQL(ReviewContext.query, host: pr.host, strings: repoVariables(pr), ints: ["number": pr.number])
        return try ReviewContext.decode(from: data)
    }

    /// Starts a pending review (visible only to the viewer until submitted); returns its ID.
    @concurrent
    public func startReview(on pr: PullRequest, pullRequestID: String) async throws -> String {
        let data = try await graphQL(
            """
            mutation($pr: ID!) { addPullRequestReview(input: {pullRequestId: $pr}) { pullRequestReview { id } } }
            """, host: pr.host, jq: ".data.addPullRequestReview.pullRequestReview.id", strings: ["pr": pullRequestID])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds a new thread to a pending review.
    @concurrent
    public func addReviewThread(on pr: PullRequest, reviewID: String, target: CommentTarget, body: String) async throws {
        var strings = ["review": reviewID, "path": target.path, "body": body, "side": target.side.rawValue]
        var ints = ["line": target.line]
        if let startLine = target.startLine, let startSide = target.startSide {
            ints["startLine"] = startLine
            strings["startSide"] = startSide.rawValue
        }
        _ = try await graphQL(
            """
            mutation($review: ID!, $path: String!, $body: String!, $line: Int!, $side: DiffSide!, $startLine: Int, $startSide: DiffSide) {
              addPullRequestReviewThread(input: {
                pullRequestReviewId: $review, path: $path, body: $body,
                line: $line, side: $side, startLine: $startLine, startSide: $startSide
              }) { thread { id } }
            }
            """, host: pr.host, strings: strings, ints: ints)
    }

    /// Replies to a thread. GitHub adds the reply to the viewer's pending review if they have one;
    /// otherwise it's posted immediately.
    @concurrent
    public func reply(on pr: PullRequest, toThread threadID: String, body: String) async throws {
        _ = try await graphQL(
            """
            mutation($thread: ID!, $body: String!) {
              addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $thread, body: $body}) { comment { id } }
            }
            """, host: pr.host, strings: ["thread": threadID, "body": body])
    }

    /// Submits the pending review, or — with no pending review — posts a review with just a summary/verdict.
    @concurrent
    public func submitReview(on pr: PullRequest, context: ReviewContext, event: ReviewEvent, body: String) async throws {
        var strings = ["event": event.rawValue]
        if !body.isEmpty { strings["body"] = body }
        if let reviewID = context.pendingReviewID {
            strings["review"] = reviewID
            _ = try await graphQL(
                """
                mutation($review: ID!, $event: PullRequestReviewEvent!, $body: String) {
                  submitPullRequestReview(input: {pullRequestReviewId: $review, event: $event, body: $body}) { pullRequestReview { id } }
                }
                """, host: pr.host, strings: strings)
        } else {
            strings["pr"] = context.pullRequestID
            _ = try await graphQL(
                """
                mutation($pr: ID!, $event: PullRequestReviewEvent!, $body: String) {
                  addPullRequestReview(input: {pullRequestId: $pr, event: $event, body: $body}) { pullRequestReview { id } }
                }
                """, host: pr.host, strings: strings)
        }
    }

    /// Deletes the pending review and all its comments.
    @concurrent
    public func discardReview(on pr: PullRequest, reviewID: String) async throws {
        _ = try await graphQL(
            """
            mutation($review: ID!) { deletePullRequestReview(input: {pullRequestReviewId: $review}) { pullRequestReview { id } } }
            """, host: pr.host, strings: ["review": reviewID])
    }

    /// Deletes one comment (used for pending ones).
    @concurrent
    public func deleteReviewComment(on pr: PullRequest, commentID: String) async throws {
        _ = try await graphQL(
            """
            mutation($id: ID!) { deletePullRequestReviewComment(input: {id: $id}) { clientMutationId } }
            """, host: pr.host, strings: ["id": commentID])
    }

    private func repoVariables(_ pr: PullRequest) -> [String: String] {
        let parts = pr.repository.nameWithOwner.split(separator: "/", maxSplits: 1)
        return ["owner": String(parts[0]), "name": String(parts[1])]
    }

    /// `-f` passes strings as-is; `-F` makes ints JSON numbers. GraphQL errors make gh exit non-zero.
    func graphQL(
        _ query: String, host: String, paginate: Bool = false, jq: String? = nil,
        strings: [String: String] = [:], ints: [String: Int] = [:]
    ) async throws -> Data {
        var arguments = ["api", "graphql", "--hostname", host]
        if paginate { arguments.append("--paginate") }
        if let jq { arguments += ["--jq", jq] }
        for (key, value) in strings.sorted(by: { $0.key < $1.key }) { arguments += ["-f", "\(key)=\(value)"] }
        for (key, value) in ints.sorted(by: { $0.key < $1.key }) { arguments += ["-F", "\(key)=\(value)"] }
        arguments += ["-f", "query=\(query)"]
        return try await run(arguments)
    }
}
