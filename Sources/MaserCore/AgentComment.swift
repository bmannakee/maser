// Line comments the review agent adds to the user's pending review.
//
// The agent asks with `add_review_comment` (path, line, optional start line and side, body). `AgentComment` turns that
// into a `CommentTarget` on the diff, refusing lines GitHub won't take comments on, and appends the attribution line
// that says, on GitHub too, that an agent drafted it. Maser recognizes the agent's comments by that line, so the badge
// in the comments pane and the question in Finish Review need nothing else stored (RC-26).

import Foundation

/// The review agent's line comments.
public enum AgentComment {
    /// What the agent sends to `add_review_comment`.
    public struct Request: Decodable, Equatable, Sendable {
        /// The file's path in the PR's head.
        public let path: String
        /// The last line the comment covers.
        public let line: Int
        /// The first line, for a range.
        public let startLine: Int?
        /// The side the numbers count on; RIGHT (the new lines) if not given.
        public let side: DiffSide?
        /// The comment's Markdown.
        public let body: String

        private enum CodingKeys: String, CodingKey {
            case path, line, side, body
            case startLine = "start_line"
        }

        /// Reads the tool's arguments.
        ///
        /// - Parameter arguments: The JSON object the agent sent.
        /// - Returns: The request.
        /// - Throws: `DecodingError` if a required field is missing or has the wrong type.
        public static func decode(_ arguments: String) throws -> Request {
            try JSONDecoder().decode(Request.self, from: Data(arguments.utf8))
        }
    }

    /// The start of the line that marks a comment as the agent's.
    static let marker = "_Drafted by an agent ("

    /// The comment's body as posted: the agent's text, then a rule and the attribution line.
    ///
    /// - Parameters:
    ///   - text: The agent's Markdown.
    ///   - model: The model the agent ran on, named in the attribution.
    /// - Returns: The body to post.
    public static func body(_ text: String, model: String) -> String {
        "\(text.trimmingCharacters(in: .whitespacesAndNewlines))\n\n---\n\(marker)\(model)) in Maser._"
    }

    /// Whether a comment's body carries the agent's attribution line.
    ///
    /// - Parameter body: The comment's Markdown.
    /// - Returns: True for a comment Maser posted for the agent.
    public static func isAgents(_ body: String) -> Bool {
        body.split(separator: "\n").last.map { $0.hasPrefix(marker) && $0.hasSuffix(" in Maser._") } ?? false
    }

    /// Finds where a requested comment goes in the diff.
    ///
    /// - Parameters:
    ///   - request: The agent's request.
    ///   - files: The PR's diff, as the Files tab parsed it.
    /// - Returns: The target, or a sentence telling the agent why the lines can't take a comment.
    public static func target(for request: Request, in files: [FileDiff]) -> Result<CommentTarget, Refusal> {
        guard let file = files.first(where: { $0.path == request.path }) else {
            return .failure(Refusal("\(request.path) isn't in the PR's diff, so GitHub won't take a comment on it."))
        }
        let side = request.side ?? .right
        let lines = request.startLine.map { "\($0)-\(request.line)" } ?? "\(request.line)"
        guard let end = file.lineID(side: side, line: request.line) else {
            return .failure(
                Refusal(
                    "Line \(request.line) (\(side.rawValue)) of \(request.path) isn't in the diff; GitHub only takes comments on lines pr_context shows."
                ))
        }
        let start = request.startLine.flatMap { file.lineID(side: side, line: $0) }
        if request.startLine != nil && start == nil {
            return .failure(Refusal("Line \(request.startLine ?? 0) of \(request.path) isn't in the diff."))
        }
        guard let target = file.commentTarget(anchor: start, cursor: end), target.line == request.line,
            target.startLine == (request.startLine == request.line ? nil : request.startLine)
        else {
            return .failure(Refusal("Lines \(lines) of \(request.path) aren't in one hunk; comment on a range within one."))
        }
        return .success(target)
    }

    /// Why a comment can't go where the agent asked.
    public struct Refusal: Error, Equatable, Sendable {
        /// The sentence for the agent.
        public let message: String

        /// Creates a refusal.
        public init(_ message: String) { self.message = message }
    }
}
