import Foundation

public enum GitHubCLIError: Error, LocalizedError {
    case notInstalled
    case failed(status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "The GitHub CLI (gh) was not found. Install it with `brew install gh` and run `gh auth login`."
        case let .failed(status, stderr):
            "gh exited with status \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Talks to GitHub through the `gh` CLI, reusing whatever account it is logged in to.
public struct GitHubCLI: Sendable {
    /// GUI apps don't inherit the shell PATH, so look in the usual install locations.
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    let executable: URL

    public init() throws {
        guard let path = Self.searchPaths
            .map({ "\($0)/gh" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw GitHubCLIError.notInstalled }
        executable = URL(fileURLWithPath: path)
    }

    /// Open PRs where the current user's review is requested.
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
