import Foundation

public enum GitHubCLIError: Error, LocalizedError {
    case notInstalled
    case failed(status: Int32, stderr: String)
    case invalidPullRequestURL(String)

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
/// Credentials stay with `gh`; the app never sees a token.
public struct GitHubCLI: Sendable {
    /// GUI apps don't inherit the shell PATH, so look in the usual install locations.
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    let executable: URL

    public init() throws {
        guard
            let path = Self.searchPaths
                .map({ "\($0)/gh" })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw GitHubCLIError.notInstalled }
        executable = URL(fileURLWithPath: path)
    }

    /// Open PRs where the current user's review is requested.
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
    @concurrent
    public func pullRequest(url: URL) async throws -> PullRequest {
        guard let nameWithOwner = PullRequest.nameWithOwner(fromURL: url) else {
            throw GitHubCLIError.invalidPullRequestURL(url.absoluteString)
        }
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

    /// Description, discussion, reviews, mergeability and CI status, in one GraphQL call.
    @concurrent
    public func overview(for pr: PullRequest) async throws -> PullRequestOverview {
        let parts = pr.repository.nameWithOwner.split(separator: "/", maxSplits: 1)
        let data = try await run([
            "api", "graphql", "--hostname", pr.host,
            // -f keeps owner/name as strings; -F makes number an Int.
            "-f", "owner=\(parts[0])",
            "-f", "name=\(parts[1])",
            "-F", "number=\(pr.number)",
            "-f", "query=\(PullRequestOverview.query)",
        ])
        return try PullRequestOverview.decode(from: data)
    }

    /// Adds a comment to the PR's conversation. `body` is Markdown.
    @concurrent
    public func addComment(to pr: PullRequest, body: String) async throws {
        _ = try await run([
            "api", "--hostname", pr.host, "--method", "POST",
            "repos/\(pr.repository.nameWithOwner)/issues/\(pr.number)/comments",
            // -f sends the text as-is (-F would treat a leading "@" as a file to read).
            "-f", "body=\(body)",
        ])
    }

    /// The PR's full diff, split into files.
    @concurrent
    public func fileDiffs(for pr: PullRequest) async throws -> [FileDiff] {
        let data = try await run([
            "pr", "diff", String(pr.number),
            "--repo", "\(pr.host)/\(pr.repository.nameWithOwner)",
            "--color", "never",
        ])
        return DiffParser.parse(String(decoding: data, as: UTF8.self))
    }

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
