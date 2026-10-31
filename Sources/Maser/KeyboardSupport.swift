import AppKit
import MaserCore
import SwiftUI

extension KeyboardShortcut {
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
            key = switch named {
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
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }

        let named: NamedKey? = switch event.keyCode {
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
    /// Menu shortcut for a command, from the current config.
    func keyboardShortcut(_ command: CommandID) -> some View {
        keyboardShortcut(ConfigStore.shared.keymap.menu[command].map(KeyboardShortcut.init))
    }

    /// Tooltip listing the command's current bindings, e.g. "Next File (⌥⌘↓ or j)".
    func help(_ text: String, _ command: CommandID) -> some View {
        help(ConfigStore.shared.bindingSummary(for: command).map { "\(text) (\($0))" } ?? text)
    }

    /// Lets the window this view is in run commands from vim-style keys (see `KeyRouter`).
    /// App-wide commands (open PR, open config, shortcuts) are handled for every window.
    func commandHandler(_ perform: @escaping @MainActor (CommandID) -> Bool) -> some View {
        modifier(CommandHandlerModifier(perform: perform))
    }
}

/// A menu button whose title and shortcut come from the command.
struct CommandButton: View {
    let command: CommandID
    var title: String?
    let action: () -> Void

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
    static func perform(_ command: CommandID, openWindow: OpenWindowAction) -> Bool {
        switch command {
        case .openPullRequest: openWindow(id: OpenPullRequestView.windowID)
        case .openConfig: ConfigStore.shared.openConfigFile()
        case .showKeybindings: openWindow(id: KeybindingsView.windowID)
        default: return false
        }
        return true
    }
}

private struct CommandHandlerModifier: ViewModifier {
    let perform: @MainActor (CommandID) -> Bool
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.background(WindowReader { [perform, openWindow] window in
            KeyRouter.shared.register(window) { command in
                GlobalCommands.perform(command, openWindow: openWindow) || perform(command)
            }
        })
    }
}

/// Reports the NSWindow hosting a SwiftUI view.
private struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(onWindow: onWindow)
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onWindow = onWindow
        if let window = view.window { onWindow(window) }
    }

    final class ReaderView: NSView {
        var onWindow: @MainActor (NSWindow) -> Void

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
