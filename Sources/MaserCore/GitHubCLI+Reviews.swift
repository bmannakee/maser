// The `GitHubCLI` calls for inline review threads and for writing reviews.
//
// Everything here goes through GitHub's GraphQL API with `gh api graphql`, because only GraphQL exposes the viewer's
// pending review and its draft comments. The flow is: `reviewContext(for:)` to find any pending review,
// `startReview(on:pullRequestID:)` to create one, `addReviewThread` and `reply` to add drafts, then `submitReview` or
// `discardReview`.

import Foundation

/// Inline review threads and writing reviews, through GitHub's GraphQL API.
extension GitHubCLI {
    /// Fetches every inline review thread on the PR, across all pages, including the viewer's pending comments.
    ///
    /// - Parameter pr: The pull request whose threads to load.
    /// - Returns: The threads in the order `ReviewThread.decodeLines(from:)` sorts them.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails or GitHub reports a GraphQL error, or a decoding error if the
    ///   output isn't the expected JSON.
    @concurrent
    public func reviewThreads(for pr: PullRequest) async throws -> [ReviewThread] {
        let data = try await graphQL(
            ReviewThread.query, host: pr.host, paginate: true, jq: ReviewThread.jqFilter,
            strings: try repoVariables(pr), ints: ["number": pr.number])
        return try ReviewThread.decodeLines(from: data)
    }

    /// Fetches the PR's node ID and the viewer's pending review, if they have one.
    ///
    /// - Parameter pr: The pull request to review.
    /// - Returns: What the other review calls need to write to this PR.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails, `PullRequestOverview.NotFound` if GitHub returns no such PR, or
    ///   a decoding error if the response isn't the expected JSON.
    @concurrent
    public func reviewContext(for pr: PullRequest) async throws -> ReviewContext {
        let data = try await graphQL(
            ReviewContext.query, host: pr.host, strings: try repoVariables(pr), ints: ["number": pr.number])
        return try ReviewContext.decode(from: data)
    }

    /// Starts a pending review, visible only to the viewer until it's submitted.
    ///
    /// - Parameters:
    ///   - pr: The pull request to review, used for its host.
    ///   - pullRequestID: The PR's GraphQL node ID, from `ReviewContext.pullRequestID`.
    /// - Returns: The new review's node ID.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails, for example when the viewer already has a pending review.
    @concurrent
    public func startReview(on pr: PullRequest, pullRequestID: String) async throws -> String {
        let data = try await graphQL(
            """
            mutation($pr: ID!) { addPullRequestReview(input: {pullRequestId: $pr}) { pullRequestReview { id } } }
            """, host: pr.host, jq: ".data.addPullRequestReview.pullRequestReview.id", strings: ["pr": pullRequestID])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds a new thread to a pending review.
    ///
    /// - Parameters:
    ///   - pr: The pull request being reviewed, used for its host.
    ///   - reviewID: The pending review's node ID.
    ///   - target: The line or range to attach the thread to; a range sends `startLine` and `startSide` as well.
    ///   - body: The comment's Markdown source.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails, for example when the target isn't a line in the PR's diff.
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

    /// Replies to a review thread.
    ///
    /// GitHub adds the reply to the viewer's pending review if they have one; otherwise it's posted immediately.
    ///
    /// - Parameters:
    ///   - pr: The pull request the thread is on, used for its host.
    ///   - threadID: The thread's node ID, from `ReviewThread.id`.
    ///   - body: The reply's Markdown source.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails.
    @concurrent
    public func reply(on pr: PullRequest, toThread threadID: String, body: String) async throws {
        _ = try await graphQL(
            """
            mutation($thread: ID!, $body: String!) {
              addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $thread, body: $body}) { comment { id } }
            }
            """, host: pr.host, strings: ["thread": threadID, "body": body])
    }

    /// Submits the viewer's review with a verdict.
    ///
    /// With a pending review, this submits it along with its draft comments. Without one, it posts a new review that has
    /// only the verdict and summary.
    ///
    /// - Parameters:
    ///   - pr: The pull request being reviewed, used for its host.
    ///   - context: The PR's node ID and pending review, from `reviewContext(for:)`.
    ///   - event: The verdict.
    ///   - body: The review summary's Markdown source; empty to submit without one.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails, for example when GitHub requires a summary for the verdict or
    ///   when the viewer tries to approve or request changes on their own PR.
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

    /// Deletes a pending review and all its draft comments.
    ///
    /// GitHub takes a few seconds to stop returning the deleted drafts from `reviewThreads(for:)`.
    ///
    /// - Parameters:
    ///   - pr: The pull request being reviewed, used for its host.
    ///   - reviewID: The pending review's node ID.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails.
    @concurrent
    public func discardReview(on pr: PullRequest, reviewID: String) async throws {
        _ = try await graphQL(
            """
            mutation($review: ID!) { deletePullRequestReview(input: {pullRequestReviewId: $review}) { pullRequestReview { id } } }
            """, host: pr.host, strings: ["review": reviewID])
    }

    /// Deletes one review comment; the app uses it to remove a draft from the pending review.
    ///
    /// - Parameters:
    ///   - pr: The pull request the comment is on, used for its host.
    ///   - commentID: The comment's node ID, from `ReviewComment.id`.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails.
    @concurrent
    public func deleteReviewComment(on pr: PullRequest, commentID: String) async throws {
        _ = try await graphQL(
            """
            mutation($id: ID!) { deletePullRequestReviewComment(input: {id: $id}) { clientMutationId } }
            """, host: pr.host, strings: ["id": commentID])
    }

    /// Returns the `owner` and `name` GraphQL variables for the PR's repository.
    ///
    /// - Throws: `GitHubCLIError.invalidPullRequestURL` if the repository name isn't `owner/name`.
    func repoVariables(_ pr: PullRequest) throws -> [String: String] {
        let parts = pr.repository.nameWithOwner.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { throw GitHubCLIError.invalidPullRequestURL(pr.url.absoluteString) }
        return ["owner": String(parts[0]), "name": String(parts[1])]
    }

    /// Runs a GraphQL query or mutation through `gh api graphql`.
    ///
    /// Strings are passed with `-f`, which sends them as-is, and ints with `-F`, which makes them JSON numbers. Variables
    /// are passed in sorted order so the arguments are deterministic.
    ///
    /// - Parameters:
    ///   - query: The GraphQL document.
    ///   - host: The GitHub host to send it to.
    ///   - paginate: Whether to fetch every page; the query must take an `$endCursor` variable and select `pageInfo`.
    ///   - jq: A `jq` filter applied to each page of output.
    ///   - strings: String variables.
    ///   - ints: Integer variables.
    /// - Returns: `gh`'s standard output: the JSON response, or the `jq` filter's output.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails; GraphQL errors in the response also make it exit non-zero.
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
