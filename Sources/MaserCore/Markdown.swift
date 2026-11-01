import Foundation

public enum Markdown {
    /// Appends `source` as a Markdown block quote to a comment draft, leaving the cursor's
    /// natural spot (a blank line after the quote) ready for the reply.
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
