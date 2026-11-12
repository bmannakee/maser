// The review agent's copy of a PR's repository: a read-only checkout of the head commit, owned by Maser.
//
// Maser keeps a bare cache per repository under its own folder. To get a commit into it, it first fetches from the
// user's own clone, if one is found, which only reads that clone, and otherwise from GitHub, with `gh` as git's
// credential helper so Maser never sees a token. It then checks the commit out as a detached worktree with symlinks off
// and hooks off, and makes every file read-only. Nothing here writes to the user's clone (RC-23).

import Foundation

/// Prepares read-only checkouts of PR head commits for the review agent.
public struct AgentCheckout: Sendable {
    /// A repository on a GitHub host.
    public struct Repository: Equatable, Hashable, Sendable {
        /// The host, lowercased, such as `github.com`.
        public let host: String
        /// The owner, lowercased.
        public let owner: String
        /// The repository's name, lowercased, without `.git`.
        public let name: String

        /// Creates a repository from its parts, lowercasing them.
        public init(host: String, owner: String, name: String) {
            self.host = host.lowercased()
            self.owner = owner.lowercased()
            self.name = name.lowercased()
        }

        /// The repository a PR belongs to.
        ///
        /// - Parameter pr: The pull request.
        public init(_ pr: PullRequest) {
            let parts = pr.repository.nameWithOwner.split(separator: "/").map(String.init)
            self.init(host: pr.host, owner: parts.first ?? "", name: parts.last ?? "")
        }

        /// Parses a git remote URL in any of the forms GitHub gives.
        ///
        /// `https://host/owner/name(.git)`, `ssh://git@host/owner/name(.git)` and `git@host:owner/name(.git)`.
        ///
        /// Fails for any other form.
        ///
        /// - Parameter remote: The URL as `git config` stores it.
        public init?(remoteURL remote: String) {
            var text = remote.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("/") { text.removeLast() }
            if text.hasSuffix(".git") { text.removeLast(4) }
            let host: String
            let path: String
            if let url = URL(string: text), let scheme = url.scheme, ["https", "http", "ssh", "git"].contains(scheme),
                let urlHost = url.host()
            {
                host = urlHost
                path = url.path()
            } else if let at = text.firstIndex(of: "@"), let colon = text[at...].firstIndex(of: ":"), !text.contains("://") {
                host = String(text[text.index(after: at)..<colon])
                path = String(text[text.index(after: colon)...])
            } else {
                return nil
            }
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count == 2, !host.isEmpty else { return nil }
            self.init(host: host, owner: parts[0], name: parts[1])
        }

        /// The repository's HTTPS URL, for fetching from GitHub.
        public var httpsURL: String { "https://\(host)/\(owner)/\(name).git" }
    }

    /// Why a checkout couldn't be made.
    public enum Failure: Error, Equatable, LocalizedError {
        /// A git command failed.
        case git(command: String, message: String)
        /// The commit isn't in the user's clone or on GitHub, for example after a force-push.
        case commitNotFound(String)

        /// A sentence for the Agent tab.
        public var errorDescription: String? {
            switch self {
            case let .git(command, message): "git \(command) failed: \(message)"
            case let .commitNotFound(commit):
                "Commit \(commit.prefix(7)) wasn't found locally or on GitHub; it may have been force-pushed away. Refresh the PR."
            }
        }
    }

    /// The folder holding the caches and checkouts.
    public let root: URL
    /// The git executable.
    public let git: URL

    /// Creates a checkout maker.
    ///
    /// - Parameters:
    ///   - root: The folder to keep caches and checkouts in, which Maser owns.
    ///   - git: The git executable; the Xcode command-line tools' by default.
    public init(root: URL, git: URL = URL(filePath: "/usr/bin/git")) {
        self.root = root
        self.git = git
    }

    /// The bare cache for a repository.
    ///
    /// - Parameter repository: The repository.
    /// - Returns: Its folder, whether or not it exists yet.
    public func cacheURL(for repository: Repository) -> URL {
        root.appending(path: repository.host).appending(path: repository.owner).appending(path: "\(repository.name).git")
    }

    /// The checkout of one commit.
    ///
    /// - Parameters:
    ///   - repository: The repository.
    ///   - commit: The commit's full ID.
    /// - Returns: Its folder, whether or not it exists yet.
    public func checkoutURL(for repository: Repository, commit: String) -> URL {
        root.appending(path: repository.host).appending(path: repository.owner)
            .appending(path: "\(repository.name)@\(commit.prefix(12))")
    }

    /// Looks for the user's own clone of a repository.
    ///
    /// Checks each folder, and the folders directly inside it, for a git repository with a remote pointing at the
    /// repository. It only reads: `git config` on each candidate.
    ///
    /// - Parameters:
    ///   - repository: The repository to find.
    ///   - folders: Where to look, from `[agent] repositories`; `~` is expanded.
    /// - Returns: The clone's folder, or nil if none was found.
    public func findLocalClone(of repository: Repository, in folders: [String]) async -> URL? {
        let fileManager = FileManager.default
        for folder in folders {
            let base = URL(filePath: NSString(string: folder).expandingTildeInPath)
            let children = (try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            for candidate in [base] + children.sorted(by: { $0.path() < $1.path() }) {
                guard fileManager.fileExists(atPath: candidate.appending(path: ".git").path(percentEncoded: false)) else {
                    continue
                }
                let result = try? await run([
                    "-C", candidate.path(percentEncoded: false), "config", "--get-regexp", #"^remote\..*\.url$"#,
                ])
                let remotes = String(decoding: result?.stdout ?? Data(), as: UTF8.self).split(separator: "\n")
                    .compactMap { $0.split(separator: " ", maxSplits: 1).last.map(String.init) }
                if remotes.contains(where: { Repository(remoteURL: $0) == repository }) { return candidate }
            }
        }
        return nil
    }

    /// Makes, or reuses, a read-only checkout of a PR's head commit.
    ///
    /// - Parameters:
    ///   - repository: The PR's repository.
    ///   - commit: The head commit's full ID.
    ///   - pullNumber: The PR's number, to fetch its head ref when the commit isn't otherwise reachable.
    ///   - localClone: The user's own clone, to fetch from first, if one was found.
    ///   - remote: Where to fetch from when the clone doesn't have the commit; GitHub's HTTPS URL normally.
    ///   - credentialHelper: A git credential helper for the remote, such as `!/opt/homebrew/bin/gh auth git-credential`.
    /// - Returns: The checkout's folder.
    /// - Throws: `Failure.commitNotFound` if neither source has the commit, or `Failure.git` if a git command fails.
    @concurrent
    public func prepare(
        _ repository: Repository, commit: String, pullNumber: Int, localClone: URL?, remote: String,
        credentialHelper: String?
    ) async throws -> URL {
        let checkout = checkoutURL(for: repository, commit: commit)
        if FileManager.default.fileExists(atPath: checkout.path(percentEncoded: false)),
            let head = try? await git(["-C", checkout.path(percentEncoded: false), "rev-parse", "HEAD"]), head == commit
        {
            return checkout
        }
        let cache = cacheURL(for: repository)
        let cachePath = cache.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: cachePath) {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            _ = try await git(["init", "--quiet", "--bare", cachePath])
            // A link in the PR arrives as a plain file holding its target's path, so it can't lead the agent outside.
            _ = try await git(["-C", cachePath, "config", "core.symlinks", "false"])
        }

        if !(await hasCommit(commit, in: cachePath)), let localClone {
            // Fetching from a local path only reads it: git runs upload-pack there, which writes nothing.
            _ = try? await git([
                "-C", cachePath, "fetch", "--quiet", "--no-tags", localClone.path(percentEncoded: false),
                "+refs/heads/*:refs/maser/local/heads/*", "+refs/remotes/*:refs/maser/local/remotes/*",
                "+refs/pull/*:refs/maser/local/pull/*",
            ])
        }
        if !(await hasCommit(commit, in: cachePath)) {
            // Replace any credential helper the user configured with gh's, for this command only.
            let credentials = credentialHelper.map { ["-c", "credential.helper=", "-c", "credential.helper=\($0)"] } ?? []
            let fetch = credentials + ["-C", cachePath, "fetch", "--quiet", "--no-tags", remote]
            if (try? await git(fetch + [commit])) == nil {
                _ = try? await git(fetch + ["+refs/pull/\(pullNumber)/head:refs/maser/pull/\(pullNumber)"])
            }
        }
        guard await hasCommit(commit, in: cachePath) else { throw Failure.commitNotFound(commit) }

        if FileManager.default.fileExists(atPath: checkout.path(percentEncoded: false)) {
            try Self.makeWritable(checkout)
            try FileManager.default.removeItem(at: checkout)
            _ = try? await git(["-C", cachePath, "worktree", "prune"])
        }
        // No hooks: a global post-checkout hook would otherwise run with the PR's code as its working directory.
        _ = try await git([
            "-c", "core.hooksPath=/dev/null", "-c", "core.symlinks=false", "-C", cachePath, "worktree", "add", "--quiet",
            "--detach", checkout.path(percentEncoded: false), commit,
        ])
        try Self.makeReadOnly(checkout)
        return checkout
    }

    /// Whether a bare repository has a commit.
    ///
    /// - Parameters:
    ///   - commit: The commit's ID.
    ///   - repository: The repository's path.
    /// - Returns: True if the commit object is there.
    private func hasCommit(_ commit: String, in repository: String) async -> Bool {
        (try? await git(["-C", repository, "cat-file", "-e", "\(commit)^{commit}"])) != nil
    }

    /// Runs git and returns its trimmed standard output.
    ///
    /// - Parameter arguments: The arguments.
    /// - Returns: Standard output, without surrounding whitespace.
    /// - Throws: `Failure.git` with git's message if it exits with a non-zero status.
    private func git(_ arguments: [String]) async throws -> String {
        let result = try await run(arguments)
        guard result.status == 0 else {
            let command = arguments.first { !$0.hasPrefix("-") && !$0.contains("=") && !$0.hasPrefix("/") } ?? "git"
            throw Failure.git(
                command: command,
                message: String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs git with prompts off, so a missing credential fails rather than waiting for input.
    ///
    /// - Parameter arguments: The arguments.
    /// - Returns: The finished process's status and output.
    /// - Throws: The error from launching git.
    private func run(_ arguments: [String]) async throws -> Subprocess.Result {
        try await Subprocess.run(git, arguments, environment: ["GIT_TERMINAL_PROMPT": "0"])
    }

    /// Removes write permission from every file and folder in a checkout.
    ///
    /// - Parameter folder: The checkout.
    /// - Throws: A file system error.
    static func makeReadOnly(_ folder: URL) throws {
        try setWritable(false, in: folder)
    }

    /// Restores the owner's write permission in a checkout, so it can be removed.
    ///
    /// - Parameter folder: The checkout.
    /// - Throws: A file system error.
    static func makeWritable(_ folder: URL) throws {
        try setWritable(true, in: folder)
    }

    /// Sets or clears write permission on a folder and everything in it, leaving symlinks alone.
    ///
    /// - Parameters:
    ///   - writable: Whether the owner may write.
    ///   - folder: The folder.
    /// - Throws: A file system error.
    private static func setWritable(_ writable: Bool, in folder: URL) throws {
        let fileManager = FileManager.default
        var paths = [folder.path(percentEncoded: false)]
        if let enumerator = fileManager.enumerator(atPath: folder.path(percentEncoded: false)) {
            for case let relative as String in enumerator {
                paths.append(folder.appending(path: relative).path(percentEncoded: false))
            }
        }
        for path in paths {
            let attributes = try fileManager.attributesOfItem(atPath: path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
            else { continue }
            let newMode = writable ? mode | 0o200 : mode & ~0o222
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: newMode)], ofItemAtPath: path)
        }
    }
}
