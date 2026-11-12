// The app's connection to GitHub: a thin wrapper around the `gh` command-line tool.
//
// `GitHubCLI` finds `gh`, runs it as a subprocess and decodes its output into MaserCore models. This file has the
// read calls for the PR list, overview and diff, plus conversation comments. Review threads and writing reviews live in
// `GitHubCLI+Reviews.swift`.

import Foundation
import Synchronization

/// An error from running `gh` or from the input given to it.
public enum GitHubCLIError: Error, LocalizedError {
    /// `gh` isn't in any of `GitHubCLI.searchPaths`, and the login shell couldn't find it either.
    case notInstalled
    /// The `gh` path set in `config.toml` isn't an executable file.
    case configuredPathNotExecutable(String)
    /// `gh` exited with a non-zero status; `stderr` holds its error output.
    case failed(status: Int32, stderr: String)
    /// The URL isn't a pull request URL of the form `https://host/owner/repo/pull/123`.
    case invalidPullRequestURL(String)
    /// GitHub accepted a request but didn't do it, with an explanation for the user.
    case rejected(String)
    /// A file was too big to show in full.
    case fileTooLarge(path: String, bytes: Int)
    /// The PR's head moved after the diff was loaded, so posting would apply to commits the user hasn't seen.
    case headMoved(seen: String, current: String)
    /// `gh` is signed in to a different account than the one shown, or none was shown yet.
    case accountChanged(shown: String?, current: String?)

    /// A user-facing message; for `failed`, it includes the error output from `gh`.
    public var errorDescription: String? {
        switch self {
        case let .invalidPullRequestURL(url):
            "Not a pull request URL: \(url)"
        case .notInstalled:
            """
            The GitHub CLI (gh) was not found. Install it with `brew install gh` and run `gh auth login`, or set its \
            location in config.toml: gh = "/path/to/gh" under [github].
            """
        case let .configuredPathNotExecutable(path):
            "The gh set in config.toml ([github] gh = \"\(path)\") isn't an executable file."
        case let .failed(status, stderr):
            "gh exited with status \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .rejected(message):
            message
        case let .fileTooLarge(path, bytes):
            "\(path) is too large to show in full (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))."
        case let .headMoved(seen, current):
            """
            New commits were pushed since this diff loaded (\(seen.prefix(7)) → \(current.prefix(7))), so nothing was \
            posted. Refresh to review them; your text is kept.
            """
        case let .accountChanged(shown, current?):
            """
            gh is signed in as @\(current)\(shown.map { ", not @\($0) as shown" } ?? ""), so nothing was posted. Post \
            again to post as @\(current), or switch accounts with gh auth switch; your text is kept.
            """
        case .accountChanged(_, nil):
            "GitHub didn't say which account gh is signed in to, so nothing was posted. Your text is kept."
        }
    }
}

/// Talks to GitHub through the `gh` CLI, reusing whatever account it is logged in to.
///
/// Credentials stay with `gh`; the app never sees a token. Every call runs `gh` as a subprocess off the main actor.
public struct GitHubCLI: Sendable {
    /// The directories searched for `gh`, in order, before asking the login shell.
    ///
    /// GUI apps don't inherit the shell's `PATH`, so these are the usual install locations: Homebrew, the system,
    /// MacPorts, Nix, user-local installs, and mise and asdf shims. `~` is expanded.
    static let searchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/opt/local/bin",
        "~/.nix-profile/bin", "/run/current-system/sw/bin", "/nix/var/nix/profiles/default/bin",
        "~/.local/bin", "~/bin", "~/.local/share/mise/shims", "~/.asdf/shims",
    ]

    /// Where `gh` is: the path set in `config.toml` (if any) and the executable found, cached once found.
    private static let location = Mutex<(configured: String?, found: URL?)>((nil, nil))

    /// Creates a client.
    ///
    /// Finding `gh` is left to the first call, which happens off the main actor.
    public init() {}

    /// Sets the `gh` executable to use instead of searching for one, from `config.toml`.
    ///
    /// - Parameter path: The path to `gh`, with `~` allowed, or `nil` to search the usual places.
    public static func setConfiguredExecutable(_ path: String?) {
        location.withLock { location in
            guard location.configured != path else { return }
            location = (path, nil)
        }
    }

    /// Returns the `gh` executable, finding it the first time.
    ///
    /// Uses the configured path if there is one. Otherwise it checks `searchPaths`, and then asks the user's login
    /// shell, which knows the `PATH` set up in their shell profile.
    ///
    /// - Returns: The executable's URL.
    /// - Throws: `GitHubCLIError.configuredPathNotExecutable` or `GitHubCLIError.notInstalled`.
    @concurrent
    static func executable() async throws -> URL {
        let (configured, found) = location.withLock { $0 }
        if let found { return found }
        let url: URL
        if let configured {
            let path = NSString(string: configured).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: path) else {
                throw GitHubCLIError.configuredPathNotExecutable(configured)
            }
            url = URL(filePath: path)
        } else if let path = searchPaths.lazy
            .map({ NSString(string: $0).appendingPathComponent("gh") })
            .map({ NSString(string: $0).expandingTildeInPath })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        {
            url = URL(filePath: path)
        } else if let path = await pathFromLoginShell() {
            url = URL(filePath: path)
        } else {
            throw GitHubCLIError.notInstalled
        }
        location.withLock { location in
            // Keep it only if the config didn't change meanwhile.
            if location.configured == configured { location.found = url }
        }
        return url
    }

    /// Asks the user's login shell where `gh` is, giving up after five seconds.
    ///
    /// - Returns: The absolute path of an executable `gh`, or `nil` if the shell doesn't find one.
    private static func pathFromLoginShell() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard
            let result = try? await Subprocess.run(
                URL(filePath: shell), ["-l", "-c", "command -v gh"], timeout: .seconds(5)),
            result.status == 0
        else { return nil }
        // Shell profiles can print other things; the answer is the last line that's an executable path.
        return String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a pull request search, such as one section of the review queue.
    ///
    /// - Parameters:
    ///   - search: The search; open PRs only unless its query picks a state.
    ///   - limit: The most PRs to return.
    /// - Returns: The PRs in the order `gh search prs` returns them.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails, for example on a query GitHub can't parse, or a decoding error
    ///   if its output isn't the expected JSON.
    @concurrent
    public func searchPullRequests(_ search: PullRequestSearch, limit: Int = 100) async throws -> [PullRequest] {
        try PullRequest.decodeList(from: await run(Self.searchArguments(for: search, limit: limit)))
    }

    /// The `gh` arguments for a pull request search.
    ///
    /// The search's words go after `--`, so a word such as `-label:wip` isn't taken for a flag.
    ///
    /// - Parameters:
    ///   - search: The search.
    ///   - limit: The most PRs to return.
    /// - Returns: The arguments, starting with `search prs`.
    static func searchArguments(for search: PullRequestSearch, limit: Int) -> [String] {
        ["search", "prs", "--limit", String(limit), "--json", PullRequest.jsonFields, "--"] + search.searchWords
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

    /// Fetches a PR's description, discussion, reviews, mergeability and CI status.
    ///
    /// One GraphQL call usually gets everything. When a PR has more comments, reviews or checks than fit in one page,
    /// that list is then fetched in full.
    ///
    /// - Parameter pr: The pull request to load.
    /// - Returns: The PR's overview.
    /// - Throws: `GitHubCLIError.failed` if `gh` fails, `PullRequestOverview.NotFound` if GitHub returns no such PR, or
    ///   a decoding error if the response isn't the expected JSON.
    @concurrent
    public func overview(for pr: PullRequest) async throws -> PullRequestOverview {
        let variables = try repoVariables(pr)
        let data = try await graphQL(PullRequestOverview.query, host: pr.host, strings: variables, ints: ["number": pr.number])
        var overview = try PullRequestOverview.decode(from: data)
        for list in PullRequestOverview.PagedList.allCases where overview.incompleteLists.contains(list) {
            let (query, jq) = PullRequestOverview.pagedQuery(for: list)
            let lines = try await graphQL(
                query, host: pr.host, paginate: true, jq: jq, strings: variables, ints: ["number": pr.number])
            try overview.replace(list, withLines: lines)
        }
        return overview
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

    /// Fetches a file's contents as of a commit.
    ///
    /// - Parameters:
    ///   - pr: The pull request whose repository holds the file.
    ///   - path: The file's path, relative to the repository root.
    ///   - commitID: The commit to read the file at, such as `ReviewContext.headCommitID`.
    ///   - maxBytes: The largest file to accept.
    /// - Returns: The file's text, decoded as UTF-8.
    /// - Throws: `GitHubCLIError.fileTooLarge` above `maxBytes`, or `GitHubCLIError.failed` if `gh` fails, for example
    ///   when the path isn't a file at that commit.
    @concurrent
    public func fileContents(
        of pr: PullRequest, path: String, commitID: String, maxBytes: Int = 4_000_000
    ) async throws -> String {
        // Encode each path component, so names with spaces, `#` or `?` stay part of the path.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#;")
        let encodedPath = path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
        let data = try await run([
            "api", "--hostname", pr.host,
            "-H", "Accept: application/vnd.github.raw+json",
            "repos/\(pr.repository.nameWithOwner)/contents/\(encodedPath)?ref=\(commitID)",
        ])
        guard data.count <= maxBytes else { throw GitHubCLIError.fileTooLarge(path: path, bytes: data.count) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs `gh` with `arguments` and waits for it to exit.
    ///
    /// The wait doesn't tie up a thread, so many `gh` processes can run at once without starving other async work.
    ///
    /// - Parameter arguments: The arguments to pass to `gh`, not including the executable.
    /// - Returns: Everything `gh` wrote to standard output.
    /// - Throws: `GitHubCLIError.failed` with `gh`'s standard error if it exits with a non-zero status, the errors from
    ///   `executable()` if `gh` can't be found, or the error from `Process.run()` if it can't be launched.
    @concurrent
    func run(_ arguments: [String]) async throws -> Data {
        let result = try await Subprocess.run(try await Self.executable(), arguments)
        guard result.status == 0 else {
            throw GitHubCLIError.failed(status: result.status, stderr: String(decoding: result.stderr, as: UTF8.self))
        }
        return result.stdout
    }
}

/// Runs a subprocess and collects its output without blocking a thread while it runs.
enum Subprocess {
    /// What a finished subprocess produced.
    struct Result: Sendable {
        /// The exit status; for a process killed by a signal, the signal number.
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    /// Runs an executable to completion.
    ///
    /// Both output pipes are drained as data arrives, so a process with lots of output can't stall on a full pipe.
    ///
    /// - Parameters:
    ///   - executable: The program to run.
    ///   - arguments: Its arguments.
    ///   - timeout: How long to let it run before terminating it, or `nil` for no limit.
    ///   - environment: Variables to set on top of this process's environment.
    /// - Returns: The exit status and everything written to standard output and standard error.
    /// - Throws: The error from `Process.run()` if the program can't be launched.
    static func run(
        _ executable: URL, _ arguments: [String], timeout: Duration? = nil, environment: [String: String] = [:]
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let output = Output()
        // Three things must finish before the result is ready: end of standard output, end of standard error, and exit.
        let group = DispatchGroup()
        for (pipe, isStdout) in [(stdout, true), (stderr, false)] {
            group.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    group.leave()
                } else {
                    output.append(data, toStdout: isStdout)
                }
            }
        }
        group.enter()
        process.terminationHandler = { _ in group.leave() }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        let timer = timeout.map { timeout in
            Task {
                try await Task.sleep(for: timeout)
                process.terminate()
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { continuation.resume() }
        }
        timer?.cancel()
        let (out, err) = output.contents
        return Result(status: process.terminationStatus, stdout: out, stderr: err)
    }

    /// Output collected from the pipes' handlers, which run on arbitrary threads.
    ///
    /// `@unchecked Sendable` is safe because every access to the buffers holds `lock`.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()

        /// Appends a chunk read from one of the pipes.
        func append(_ data: Data, toStdout: Bool) {
            lock.withLock {
                if toStdout { stdout.append(data) } else { stderr.append(data) }
            }
        }

        /// Everything collected so far from standard output and standard error.
        var contents: (Data, Data) { lock.withLock { (stdout, stderr) } }
    }
}
