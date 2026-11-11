// Text the user has written for a PR but not yet posted, and the files that keep it across crashes and quits.
//
// `UnsentText` holds one PR's conversation comment, line comment or reply, and review summary. `UnsentTextStore` keeps
// one small JSON file per PR, written as the user types, so a crash or quit loses nothing; the review model reads it
// back when the PR is opened again and clears each part once it's posted or discarded.

import Foundation

/// What a line comment or reply being written will be posted as.
public enum DraftTarget: Codable, Equatable, Sendable {
    /// A new review thread on a line or range of lines.
    case newThread(CommentTarget)
    /// A reply to an existing thread, with the login of the thread's first commenter.
    case reply(threadID: String, to: String)
}

/// The text written for one PR that hasn't been posted.
public struct UnsentText: Codable, Equatable, Sendable {
    /// A line comment or reply being written.
    public struct LineComment: Codable, Equatable, Sendable {
        /// What it will be posted as.
        public var target: DraftTarget
        /// The head commit of the diff a new thread's lines were chosen on.
        public var commitID: String?
        /// The Markdown source.
        public var body: String

        /// Creates a line comment.
        public init(target: DraftTarget, commitID: String?, body: String) {
            self.target = target
            self.commitID = commitID
            self.body = body
        }
    }

    /// The comment for the PR's conversation.
    public var comment = ""
    /// The line comment or reply, if one has text.
    public var lineComment: LineComment?
    /// The summary for Finish Review.
    public var reviewSummary = ""

    /// Creates unsent text; everything is empty by default.
    public init(comment: String = "", lineComment: LineComment? = nil, reviewSummary: String = "") {
        self.comment = comment
        self.lineComment = lineComment
        self.reviewSummary = reviewSummary
    }

    /// Whether there is nothing worth keeping: every part is empty or only whitespace.
    public var isEmpty: Bool {
        [comment, lineComment?.body ?? "", reviewSummary].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// Keeps each PR's `UnsentText` in a file, so it survives a crash or quit.
///
/// Each PR has its own file, named for its host, repository and number. Saving empty text removes the file. Writes are
/// atomic, so a crash mid-write leaves the previous version.
public struct UnsentTextStore: Sendable {
    /// The directory holding the files.
    public let directory: URL

    /// Creates a store in a directory, which is created on the first save.
    ///
    /// - Parameter directory: Where to keep the files.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Returns the file that holds a PR's unsent text.
    ///
    /// GitHub logins and repository names can't contain spaces, so joining the parts with spaces can't collide.
    ///
    /// - Parameter pr: The pull request.
    /// - Returns: The file's URL, whether or not it exists.
    public func fileURL(for pr: PullRequest) -> URL {
        let repository = pr.repository.nameWithOwner.replacingOccurrences(of: "/", with: " ")
        return directory.appending(path: "\(pr.host) \(repository) \(pr.number).json")
    }

    /// Reads a PR's unsent text.
    ///
    /// - Parameter pr: The pull request.
    /// - Returns: The saved text, or empty text if none was saved.
    /// - Throws: An error if the file exists but can't be read or decoded.
    public func load(for pr: PullRequest) throws -> UnsentText {
        let url = fileURL(for: pr)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return UnsentText() }
        return try JSONDecoder().decode(UnsentText.self, from: Data(contentsOf: url))
    }

    /// Saves a PR's unsent text, or removes its file if the text is empty.
    ///
    /// - Parameters:
    ///   - text: The text to keep.
    ///   - pr: The pull request.
    /// - Throws: An error if the directory or file can't be written.
    public func save(_ text: UnsentText, for pr: PullRequest) throws {
        let url = fileURL(for: pr)
        if text.isEmpty {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(text).write(to: url, options: .atomic)
    }

    /// Changes one part of a PR's unsent text, leaving the parts other windows may have written.
    ///
    /// The same PR can be open in two windows, each writing a different part, so each change rereads the file. A file
    /// that can't be read is replaced.
    ///
    /// - Parameters:
    ///   - pr: The pull request.
    ///   - change: Changes the text in place.
    /// - Throws: An error if the file can't be written.
    public func update(for pr: PullRequest, _ change: (inout UnsentText) -> Void) throws {
        var text = (try? load(for: pr)) ?? UnsentText()
        change(&text)
        try save(text, for: pr)
    }
}
