import SwiftUI

/// Every user-invokable action, with a stable ID that a keybinding config can refer to.
enum CommandID: String, CaseIterable, Sendable {
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
}

/// The single source of keyboard shortcuts. All menu items and buttons look up their
/// shortcut here, so a user config only has to override this table.
@MainActor
enum Keymap {
    static let defaults: [CommandID: KeyboardShortcut] = [
        .openPullRequest: KeyboardShortcut("o"),
        .refresh: KeyboardShortcut("r"),
        .openOnGitHub: KeyboardShortcut("o", modifiers: [.command, .shift]),
        .showOverview: KeyboardShortcut("1"),
        .showFiles: KeyboardShortcut("2"),
        .toggleComments: KeyboardShortcut("0", modifiers: [.command, .option]),
        .nextFile: KeyboardShortcut(.downArrow, modifiers: [.command, .option]),
        .previousFile: KeyboardShortcut(.upArrow, modifiers: [.command, .option]),
        .nextThread: KeyboardShortcut(.downArrow, modifiers: [.command, .control]),
        .previousThread: KeyboardShortcut(.upArrow, modifiers: [.command, .control]),
    ]

    static func shortcut(for command: CommandID) -> KeyboardShortcut? {
        defaults[command]
    }

    /// Menu-style rendering, e.g. `⌥⌘↓`.
    static func display(_ command: CommandID) -> String? {
        guard let shortcut = shortcut(for: command) else { return nil }
        let modifiers: [(EventModifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let prefix = modifiers.filter { shortcut.modifiers.contains($0.0) }.map(\.1).joined()
        let key: String = switch shortcut.key {
        case .upArrow: "↑"
        case .downArrow: "↓"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .return: "↩"
        case .escape: "⎋"
        case .tab: "⇥"
        case .space: "Space"
        case .delete: "⌫"
        default: String(shortcut.key.character).uppercased()
        }
        return prefix + key
    }
}

extension View {
    func keyboardShortcut(_ command: CommandID) -> some View {
        keyboardShortcut(Keymap.shortcut(for: command))
    }

    /// Tooltip that includes the command's current shortcut.
    func help(_ text: String, _ command: CommandID) -> some View {
        help(Keymap.display(command).map { "\(text) (\($0))" } ?? text)
    }
}
