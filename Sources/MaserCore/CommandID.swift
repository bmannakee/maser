/// Every user-invokable action. The raw value is the name used in `config.toml`.
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
    case openConfig = "open-config"
    case showKeybindings = "show-keybindings"

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
        case .openConfig: "Open Config File"
        case .showKeybindings: "Keyboard Shortcuts"
        }
    }
}

extension CommandID: Identifiable {
    public var id: Self { self }
}
