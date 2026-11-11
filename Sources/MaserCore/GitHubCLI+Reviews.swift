// The `GitHubCLI` calls for inline review threads and for writing reviews.
//
// Everything here goes through GitHub's GraphQL API with `gh api graphql`, because only GraphQL exposes the viewer's
// pending review and its draft comments. The flow is: `diffAtHead(for:)` to load the diff with the commit it shows,
// `reviewContext(for:)` to check the head hasn't moved and find any pending review, `startReview` to create one pinned
// to that commit, `addReviewThread` and `reply` to add drafts, then `submitReview` or
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
        var threads = try ReviewThread.decodeLines(from: data)
        // The query gets each thread's first page of comments; fetch the rest of any longer thread.
        for index in threads.indices where threads[index].hasMoreComments {
            let comments = try await graphQL(
                ReviewThread.commentsQuery, host: pr.host, paginate: true, jq: ReviewThread.commentsJQFilter,
                strings: ["thread": threads[index].id])
            threads[index] = threads[index].replacingComments(try ReviewThread.decodeCommentLines(from: comments))
        }
        return threads
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

    /// Loads the PR's diff together with the review context, making sure both are from the same head commit.
    ///
    /// `gh pr diff` always serves the current head and doesn't say which commit that is, so the head is read before
    /// and after the diff. If a push lands in between, the load is retried.
    ///
    /// - Parameters:
    ///   - pr: The pull request to load.
    ///   - attempts: How many times to try before giving up.
    /// - Returns: The diff, and the context whose `headCommitID` is the commit the diff shows.
    /// - Throws: `GitHubCLIError.rejected` if the head keeps moving, or the errors from `fileDiffs(for:)` and
    ///   `reviewContext(for:)`.
    @concurrent
    public func diffAtHead(for pr: PullRequest, attempts: Int = 3) async throws -> (files: [FileDiff], context: ReviewContext) {
        for _ in 0..<attempts {
            let before = try await reviewContext(for: pr)
            let files = try await fileDiffs(for: pr)
            let after = try await reviewContext(for: pr)
            if before.headCommitID == after.headCommitID { return (files, after) }
        }
        throw GitHubCLIError.rejected("The PR kept changing while its diff loaded. Refresh to try again.")
    }

    /// The mutation that starts a pending review, pinned to a commit.
    static let startReviewMutation = """
        mutation($pr: ID!, $commit: GitObjectID) {
          addPullRequestReview(input: {pullRequestId: $pr, commitOID: $commit}) { pullRequestReview { id } }
        }
        """

    /// The variables for `startReviewMutation`.
    ///
    /// - Parameters:
    ///   - pullRequestID: The PR's GraphQL node ID.
    ///   - commitID: The head commit of the diff the user saw.
    /// - Returns: The `-f` string variables.
    static func startReviewVariables(pullRequestID: String, commitID: String) -> [String: String] {
        ["pr": pullRequestID, "commit": commitID]
    }

    /// Starts a pending review, visible only to the viewer until it's submitted.
    ///
    /// The review is pinned to `commitID`, so submitting it later covers that commit, not whatever was pushed since.
    /// New threads still land on the PR's current head (GitHub ignores the review's commit for them), so check the head
    /// with `ReviewContext.requireHead(_:)` before adding one.
    ///
    /// - Parameters:
    ///   - pr: The pull request to review, used for its host.
    ///   - pullRequestID: The PR's GraphQL node ID, from `ReviewContext.pullRequestID`.
    ///   - commitID: The head commit of the diff the user saw.
    /// - Returns: The new review's node ID.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails, for example when the viewer already has a pending review.
    @concurrent
    public func startReview(on pr: PullRequest, pullRequestID: String, commitID: String) async throws -> String {
        let data = try await graphQL(
            Self.startReviewMutation, host: pr.host, jq: ".data.addPullRequestReview.pullRequestReview.id",
            strings: Self.startReviewVariables(pullRequestID: pullRequestID, commitID: commitID))
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds a new thread to a pending review.
    ///
    /// - Parameters:
    ///   - pr: The pull request being reviewed, used for its host.
    ///   - reviewID: The pending review's node ID.
    ///   - target: The line or range to attach the thread to; a range sends `startLine` and `startSide` as well.
    ///   - body: The comment's Markdown source.
    /// - Throws: `GitHubCLIError.rejected` if GitHub doesn't create the thread, as when the target isn't a line in the
    ///   PR's diff, or `GitHubCLIError.failed` if `gh` fails.
    @concurrent
    public func addReviewThread(on pr: PullRequest, reviewID: String, target: CommentTarget, body: String) async throws {
        var strings = ["review": reviewID, "path": target.path, "body": body, "side": target.side.rawValue]
        var ints = ["line": target.line]
        if let startLine = target.startLine, let startSide = target.startSide {
            ints["startLine"] = startLine
            strings["startSide"] = startSide.rawValue
        }
        let id = try await graphQL(
            """
            mutation($review: ID!, $path: String!, $body: String!, $line: Int!, $side: DiffSide!, $startLine: Int, $startSide: DiffSide) {
              addPullRequestReviewThread(input: {
                pullRequestReviewId: $review, path: $path, body: $body,
                line: $line, side: $side, startLine: $startLine, startSide: $startSide
              }) { thread { id } }
            }
            """, host: pr.host, jq: ".data.addPullRequestReviewThread.thread.id // \"\"", strings: strings, ints: ints)
        // For a line outside the diff, GitHub answers with a null thread rather than an error.
        guard !String(decoding: id, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitHubCLIError.rejected(
                "GitHub didn't add the comment. Comments can only go on lines that are part of the diff.")
        }
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

    /// The mutation and variables that submit a review.
    ///
    /// A pending review is submitted as it is: it was pinned to a commit when it started. A review without one is created
    /// pinned to `commitID`.
    ///
    /// - Parameters:
    ///   - context: The PR's node ID and pending review.
    ///   - event: The verdict.
    ///   - body: The summary; empty to send none.
    ///   - commitID: The head commit of the diff the user saw.
    /// - Returns: The GraphQL document and its `-f` string variables.
    static func submitReviewRequest(
        context: ReviewContext, event: ReviewEvent, body: String, commitID: String
    ) -> (query: String, strings: [String: String]) {
        var strings = ["event": event.rawValue]
        if !body.isEmpty { strings["body"] = body }
        if let reviewID = context.pendingReviewID {
            strings["review"] = reviewID
            return (
                """
                mutation($review: ID!, $event: PullRequestReviewEvent!, $body: String) {
                  submitPullRequestReview(input: {pullRequestReviewId: $review, event: $event, body: $body}) { pullRequestReview { id } }
                }
                """, strings
            )
        }
        strings["pr"] = context.pullRequestID
        strings["commit"] = commitID
        return (
            """
            mutation($pr: ID!, $commit: GitObjectID, $event: PullRequestReviewEvent!, $body: String) {
              addPullRequestReview(input: {pullRequestId: $pr, commitOID: $commit, event: $event, body: $body}) { pullRequestReview { id } }
            }
            """, strings
        )
    }

    /// Submits the viewer's review with a verdict.
    ///
    /// With a pending review, this submits it along with its draft comments. Without one, it posts a new review that has
    /// only the verdict and summary, pinned to `commitID`.
    ///
    /// - Parameters:
    ///   - pr: The pull request being reviewed, used for its host.
    ///   - context: The PR's node ID and pending review, from `reviewContext(for:)`.
    ///   - event: The verdict.
    ///   - body: The review summary's Markdown source; empty to submit without one.
    ///   - commitID: The head commit of the diff the user saw.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails, for example when GitHub requires a summary for the verdict or
    ///   when the viewer tries to approve or request changes on their own PR.
    @concurrent
    public func submitReview(
        on pr: PullRequest, context: ReviewContext, event: ReviewEvent, body: String, commitID: String
    ) async throws {
        let request = Self.submitReviewRequest(context: context, event: event, body: body, commitID: commitID)
        _ = try await graphQL(request.query, host: pr.host, strings: request.strings)
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
