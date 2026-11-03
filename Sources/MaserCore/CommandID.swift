// The identifiers for every command a key binding or menu item can trigger.
//
// `CommandID` is the shared vocabulary between the keymap, the menu bar and the review window's command handler. Its
// raw values are the names users write in `config.toml`, so renaming one breaks existing configs.

/// Every user-invokable action.
///
/// The raw value is the name used in `config.toml`.
public enum CommandID: String, CaseIterable, Sendable {
    case openPullRequest = "open-pull-request"
    case refresh = "refresh"
    case openOnGitHub = "open-on-github"
    case showOverview = "show-overview"
    case showFiles = "show-files"
    case toggleComments = "toggle-comments"
    case nextFile = "next-file"
    case previousFile = "previous-file"
    case nextThread = "next-thread"
    case previousThread = "previous-thread"
    case cursorDown = "cursor-down"
    case cursorUp = "cursor-up"
    case nextHunk = "next-hunk"
    case previousHunk = "previous-hunk"
    case selectLines = "select-lines"
    case cancel = "cancel"
    case comment = "comment"
    case reply = "reply"
    case submitReview = "submit-review"
    case scrollDown = "scroll-down"
    case scrollUp = "scroll-up"
    case halfPageDown = "half-page-down"
    case halfPageUp = "half-page-up"
    case pageDown = "page-down"
    case pageUp = "page-up"
    case scrollToTop = "scroll-to-top"
    case scrollToBottom = "scroll-to-bottom"
    case openConfig = "open-config"
    case showKeybindings = "show-keybindings"

    /// The command's name as shown in menus and the keyboard shortcuts list.
    public var title: String {
        switch self {
        case .openPullRequest: "Open Pull Request…"
        case .refresh: "Refresh"
        case .openOnGitHub: "Open on GitHub"
        case .showOverview: "Overview"
        case .showFiles: "Files"
        case .toggleComments: "Show/Hide Comments"
        case .nextFile: "Next File"
        case .previousFile: "Previous File"
        case .nextThread: "Next Comment Thread"
        case .previousThread: "Previous Comment Thread"
        case .cursorDown: "Next Line"
        case .cursorUp: "Previous Line"
        case .nextHunk: "Next Hunk"
        case .previousHunk: "Previous Hunk"
        case .selectLines: "Select Lines"
        case .cancel: "Cancel Selection"
        case .comment: "Comment…"
        case .reply: "Reply to Thread…"
        case .submitReview: "Finish Review…"
        case .scrollDown: "Scroll Down a Line"
        case .scrollUp: "Scroll Up a Line"
        case .halfPageDown: "Scroll Down Half a Page"
        case .halfPageUp: "Scroll Up Half a Page"
        case .pageDown: "Page Down"
        case .pageUp: "Page Up"
        case .scrollToTop: "Scroll to Top"
        case .scrollToBottom: "Scroll to Bottom"
        case .openConfig: "Open Config File"
        case .showKeybindings: "Keyboard Shortcuts"
        }
    }
}

extension CommandID: Identifiable {
    /// The command itself, so commands can drive SwiftUI lists directly.
    public var id: Self { self }
}
