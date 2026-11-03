// The app's connection to GitHub: a thin wrapper around the `gh` command-line tool.
//
// `GitHubCLI` finds `gh`, runs it as a subprocess and decodes its output into MaserCore models. This file has the
// read calls for the PR list, overview and diff, plus conversation comments. Review threads and writing reviews live in
// `GitHubCLI+Reviews.swift`.

import Foundation

/// An error from running `gh` or from the input given to it.
public enum GitHubCLIError: Error, LocalizedError {
    /// `gh` isn't in any of the locations in `GitHubCLI.searchPaths`.
    case notInstalled
    /// `gh` exited with a non-zero status; `stderr` holds its error output.
    case failed(status: Int32, stderr: String)
    /// The URL isn't a pull request URL of the form `https://host/owner/repo/pull/123`.
    case invalidPullRequestURL(String)

    /// A user-facing message; for `failed`, it includes the error output from `gh`.
    public var errorDescription: String? {
        switch self {
        case let .invalidPullRequestURL(url):
            "Not a pull request URL: \(url)"
        case .notInstalled:
            "The GitHub CLI (gh) was not found. Install it with `brew install gh` and run `gh auth login`."
        case let .failed(status, stderr):
            "gh exited with status \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Talks to GitHub through the `gh` CLI, reusing whatever account it is logged in to.
///
/// Credentials stay with `gh`; the app never sees a token. Every call runs `gh` as a subprocess off the main actor.
public struct GitHubCLI: Sendable {
    /// The directories searched for `gh`, in order.
    ///
    /// GUI apps don't inherit the shell's `PATH`, so these are the usual install locations rather than a `PATH` lookup.
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// The `gh` executable that every call runs.
    let executable: URL

    /// Finds the `gh` executable.
    ///
    /// - Throws: `GitHubCLIError.notInstalled` if no executable `gh` is in `searchPaths`.
    public init() throws {
        guard
            let path = Self.searchPaths
                .map({ "\($0)/gh" })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw GitHubCLIError.notInstalled }
        executable = URL(fileURLWithPath: path)
    }

    /// Fetches the open PRs where the viewer's review is requested.
    ///
    /// - Parameter limit: The most PRs to return.
    /// - Returns: The PRs in the order `gh search prs` returns them.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails, or a decoding error if its output isn't the expected JSON.
    @concurrent
    public func reviewRequests(limit: Int = 100) async throws -> [PullRequest] {
        let data = try await run([
            "search", "prs",
            "--review-requested=@me",
            "--state=open",
            "--limit", String(limit),
            "--json", PullRequest.jsonFields,
        ])
        return try PullRequest.decodeList(from: data)
    }

    /// Looks up a single PR from its web URL, e.g. `https://github.com/owner/repo/pull/123`.
    ///
    /// The repository comes from the URL's path, since `gh pr view` doesn't report it.
    ///
    /// - Parameter url: The PR's web URL; trailing path components like `/files` are allowed.
    /// - Returns: The pull request.
    /// - Throws: `GitHubCLIError.invalidPullRequestURL` if `url` isn't a PR URL, `GitHubCLIError.failed` if `gh` fails
    ///   (for example, when the PR doesn't exist), or a decoding error if its output isn't the expected JSON.
    @concurrent
    public func pullRequest(url: URL) async throws -> PullRequest {
        guard let nameWithOwner = PullRequest.nameWithOwner(fromURL: url) else {
            throw GitHubCLIError.invalidPullRequestURL(url.absoluteString)
        }
        /// The fields requested from `gh pr view --json`.
        struct View: Decodable {
            let number: Int
            let title: String
            let url: URL
            let author: PullRequest.Author
            let updatedAt: Date
            let isDraft: Bool
        }
        let data = try await run([
            "pr", "view", url.absoluteString,
            "--json", "number,title,url,author,updatedAt,isDraft",
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let view = try decoder.decode(View.self, from: data)
        return PullRequest(
            number: view.number,
            title: view.title,
            url: view.url,
            repository: .init(name: String(nameWithOwner.split(separator: "/")[1]), nameWithOwner: nameWithOwner),
            author: view.author,
            updatedAt: view.updatedAt,
            isDraft: view.isDraft
        )
    }

    /// Fetches a PR's description, discussion, reviews, mergeability and CI status in one GraphQL call.
    ///
    /// - Parameter pr: The pull request to load.
    /// - Returns: The PR's overview.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails, `PullRequestOverview.NotFound` if GitHub returns no such PR, or
    ///   a decoding error if the response isn't the expected JSON.
    @concurrent
    public func overview(for pr: PullRequest) async throws -> PullRequestOverview {
        let data = try await graphQL(
            PullRequestOverview.query, host: pr.host, strings: try repoVariables(pr), ints: ["number": pr.number])
        return try PullRequestOverview.decode(from: data)
    }

    /// Posts a comment to the PR's conversation.
    ///
    /// - Parameters:
    ///   - pr: The pull request to comment on.
    ///   - body: The comment's Markdown source.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails, for example when the PR is locked.
    @concurrent
    public func addComment(to pr: PullRequest, body: String) async throws {
        _ = try await run([
            "api", "--hostname", pr.host, "--method", "POST",
            "repos/\(pr.repository.nameWithOwner)/issues/\(pr.number)/comments",
            // -f sends the text as-is (-F would treat a leading "@" as a file to read).
            "-f", "body=\(body)",
        ])
    }

    /// Fetches the PR's full diff, split into files.
    ///
    /// - Parameter pr: The pull request whose diff to load.
    /// - Returns: One `FileDiff` per changed file, in diff order.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails, for example when the diff is too large for GitHub to serve.
    @concurrent
    public func fileDiffs(for pr: PullRequest) async throws -> [FileDiff] {
        let data = try await run([
            "pr", "diff", String(pr.number),
            "--repo", "\(pr.host)/\(pr.repository.nameWithOwner)",
            "--color", "never",
        ])
        return DiffParser.parse(String(decoding: data, as: UTF8.self))
    }

    /// Runs `gh` with `arguments` and waits for it to exit.
    ///
    /// - Parameter arguments: The arguments to pass to `gh`, not including the executable.
    /// - Returns: Everything `gh` wrote to standard output.
    /// - Throws: `GitHubCLIError.failed` with `gh`'s standard error if it exits with a non-zero status, or the error from
    ///   `Process.run()` if `gh` can't be launched.
    @concurrent
    func run(_ arguments: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Drain both pipes concurrently so large output can't fill a pipe buffer and stall gh.
        async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
        async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
        let (outData, errData) = await (out, err)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw GitHubCLIError.failed(
                status: process.terminationStatus,
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }
        return outData
    }
}
