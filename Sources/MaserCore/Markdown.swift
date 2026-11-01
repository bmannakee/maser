// Markdown text helpers for comment drafts.
//
// Currently just quoting: the Overview tab's quote-reply uses it to quote the description, a comment or a review into
// the comment box.

import Foundation

/// Helpers for editing Markdown comment text.
public enum Markdown {
    /// Appends `source` as a Markdown block quote to a comment draft.
    ///
    /// The draft and quote are trimmed of surrounding whitespace, blank lines inside the quote stay quoted, and the
    /// result ends with a blank line after the quote, ready for the reply.
    ///
    /// - Parameters:
    ///   - source: The Markdown to quote.
    ///   - draft: The draft so far; may be empty.
    /// - Returns: The draft, a blank line if the draft wasn't empty, the quote, and a trailing blank line.
    public static func appendingQuote(of source: String, to draft: String) -> String {
        let quote =
            source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty ? "" : trimmed + "\n\n") + quote + "\n\n"
    }
}
