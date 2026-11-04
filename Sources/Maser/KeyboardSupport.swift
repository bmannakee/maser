// Glue between config key bindings and SwiftUI/AppKit.
//
// Converts `KeyChord`s to and from SwiftUI shortcuts and AppKit key events, and provides the view helpers that wire a
// command's configured bindings into menus, tooltips and `KeyRouter`: `keyboardShortcut(_:)`, `help(_:_:)`,
// `commandHandler(_:)` and `CommandButton`. Commands that act the same in every window live in `GlobalCommands`.

import AppKit
import MaserCore
import SwiftUI

extension KeyboardShortcut {
    /// The SwiftUI shortcut for a config chord.
    ///
    /// An uppercase character becomes its lowercase key plus ⇧, since that's how SwiftUI expects shifted letters.
    init(_ chord: KeyChord) {
        var modifiers: EventModifiers = []
        if chord.modifiers.contains(.command) { modifiers.insert(.command) }
        if chord.modifiers.contains(.control) { modifiers.insert(.control) }
        if chord.modifiers.contains(.option) { modifiers.insert(.option) }
        if chord.modifiers.contains(.shift) { modifiers.insert(.shift) }

        let key: KeyEquivalent
        switch chord.key {
        case let .character(character) where character.isUppercase:
            modifiers.insert(.shift)
            key = KeyEquivalent(Character(character.lowercased()))
        case let .character(character):
            key = KeyEquivalent(character)
        case let .named(named):
            key =
                switch named {
                case .up: .upArrow
                case .down: .downArrow
                case .left: .leftArrow
                case .right: .rightArrow
                case .enter: .return
                case .tab: .tab
                case .space: .space
                case .escape: .escape
                case .backspace: .delete
                case .delete: .deleteForward
                case .pageUp: .pageUp
                case .pageDown: .pageDown
                case .home: .home
                case .end: .end
                }
        }
        self.init(key, modifiers: modifiers)
    }
}

extension KeyChord {
    /// The chord a key-down event represents, in the same form config bindings use.
    ///
    /// Named keys (arrows, Return, Tab and so on) record ⇧ as a modifier. Character keys don't: their character already
    /// reflects shift (`J`, `?`). Returns `nil` for keys that produce no single character, such as dead keys.
    ///
    /// - Parameter event: A key-down event.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }

        // Virtual key codes from Carbon's `kVK_*` constants; 76 is the keypad Enter.
        let named: NamedKey? =
            switch event.keyCode {
            case 123: .left
            case 124: .right
            case 125: .down
            case 126: .up
            case 36, 76: .enter
            case 48: .tab
            case 49: .space
            case 53: .escape
            case 51: .backspace
            case 117: .delete
            case 116: .pageUp
            case 121: .pageDown
            case 115: .home
            case 119: .end
            default: nil
            }
        if let named {
            if flags.contains(.shift) { modifiers.insert(.shift) }
            self.init(named, modifiers: modifiers)
            return
        }
        // Already reflects shift (J, ?), which is how character bindings are written.
        guard let characters = event.charactersIgnoringModifiers, characters.count == 1, let character = characters.first else {
            return nil
        }
        self.init(character, modifiers: modifiers)
    }
}

extension View {
    /// Gives the view the command's menu shortcut from the current config, or none if it has no menu binding.
    func keyboardShortcut(_ command: CommandID) -> some View {
        keyboardShortcut(ConfigStore.shared.keymap.menu[command].map(KeyboardShortcut.init))
    }

    /// Adds a tooltip that lists the command's current bindings after the text, such as "Next File (⌥⌘↓ or j)".
    ///
    /// - Parameters:
    ///   - text: The tooltip text; shown alone if the command is unbound.
    ///   - command: The command whose bindings to list.
    /// - Returns: The view with the tooltip.
    func help(_ text: String, _ command: CommandID) -> some View {
        help(ConfigStore.shared.bindingSummary(for: command).map { "\(text) (\($0))" } ?? text)
    }

    /// Lets the window this view is in run commands from vim-style keys (see `KeyRouter`).
    ///
    /// The app-wide commands in `GlobalCommands` (open PR, show pull requests, open config, show keybindings) are tried
    /// first, so they work
    /// in every window that uses this, even with a handler that returns `false` for everything.
    ///
    /// - Parameter perform: Runs a window-specific command and returns `true` if it handled it.
    /// - Returns: The view, with its window registered with `KeyRouter`.
    func commandHandler(_ perform: @escaping @MainActor (CommandID) -> Bool) -> some View {
        modifier(CommandHandlerModifier(perform: perform))
    }
}

/// A menu button whose title and shortcut come from the command.
struct CommandButton: View {
    let command: CommandID
    /// Overrides `command.title`, for titles that change with state such as "Hide Comments".
    var title: String?
    let action: () -> Void

    /// Creates a button for a command.
    ///
    /// - Parameters:
    ///   - command: Supplies the default title and the configured menu shortcut.
    ///   - title: A title to use instead of the command's own.
    ///   - action: Runs when the button or its shortcut is triggered.
    init(_ command: CommandID, title: String? = nil, action: @escaping () -> Void) {
        self.command = command
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title ?? command.title, action: action)
            .keyboardShortcut(command)
    }
}

/// Commands that work the same from any window.
@MainActor
enum GlobalCommands {
    /// Runs the command if it's one of the app-wide ones.
    ///
    /// - Parameters:
    ///   - command: The command to run.
    ///   - openWindow: Opens the Open Pull Request, main and Keybindings windows.
    /// - Returns: `true` if the command was app-wide and ran; `false` to let the window handle it.
    static func perform(_ command: CommandID, openWindow: OpenWindowAction) -> Bool {
        switch command {
        case .openPullRequest: openWindow(id: OpenPullRequestView.windowID)
        case .openConfig: ConfigStore.shared.openConfigFile()
        case .showKeybindings: openWindow(id: KeybindingsView.windowID)
        case .showPullRequests: MainWindows.shared.showQueue(openWindow: openWindow)
        default: return false
        }
        return true
    }
}

/// Registers the hosting window with `KeyRouter`, trying `GlobalCommands` before the view's own handler.
private struct CommandHandlerModifier: ViewModifier {
    let perform: @MainActor (CommandID) -> Bool
    @Environment(\.openWindow) private var openWindow

    // Re-registers on every update, so the router always calls the latest closure.
    func body(content: Content) -> some View {
        content.background(
            WindowReader { [perform, openWindow] window in
                KeyRouter.shared.register(window) { command in
                    GlobalCommands.perform(command, openWindow: openWindow) || perform(command)
                }
            })
    }
}

/// Reports the `NSWindow` hosting a SwiftUI view.
///
/// Calls `onWindow` when the view joins a window and again on every SwiftUI update, so callers should expect repeats.
struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(onWindow: onWindow)
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
        if let window = view.window { onWindow(window) }
    }

    /// An empty view that reports its window when it's added to one.
    final class ReaderView: NSView {
        var onWindow: @MainActor (NSWindow) -> Void

        /// Creates a zero-size view that calls `onWindow` once it has a window.
        init(onWindow: @escaping @MainActor (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}
