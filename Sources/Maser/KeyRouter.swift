// The vim-style key router for app windows.
//
// Watches key-down events app-wide, turns plain keystrokes (and multi-key sequences like `g g`) into commands using the
// current keymap from `ConfigStore`, and hands them to the command handler registered for the event's window. ⌘ chords
// are left to the menu bar, and keys typed into text fields and editors pass through untouched.

import AppKit
import MaserCore
import os

/// Logs each key sequence that resolves to a command, for debugging bindings.
private let keyLog = Logger(subsystem: "dev.maser", category: "keys")

/// Vim-style "normal mode": turns plain keystrokes into commands whenever the user isn't typing in a text field.
///
/// Runs ahead of menu shortcuts, but ⌘ chords always go to the menus. Only windows that registered a handler
/// (through `View.commandHandler(_:)`) get vim-style keys.
@MainActor
final class KeyRouter {
    /// The app's single router, started at launch.
    static let shared = KeyRouter()

    /// How long to wait for the rest of a multi-key sequence like `g f`.
    static let sequenceTimeout: TimeInterval = 1.5

    /// A window's command callback, boxed in a class so `NSMapTable` can hold it.
    final class Handler {
        /// Runs a command; returns `true` if the window handled it.
        let perform: @MainActor (CommandID) -> Bool

        /// Wraps a window's command callback.
        init(_ perform: @escaping @MainActor (CommandID) -> Bool) { self.perform = perform }
    }

    /// Command handlers keyed by window; weak keys so closed windows drop out on their own.
    private let handlers = NSMapTable<NSWindow, Handler>.weakToStrongObjects()
    /// The token from `NSEvent.addLocalMonitorForEvents`, or `nil` before `start()`.
    private var monitor: Any?
    /// The keys typed so far of a multi-key sequence that hasn't resolved yet.
    private var pending: [KeyChord] = []
    /// When `pending` last grew, for `sequenceTimeout`.
    private var pendingSince = Date.distantPast

    /// Sets the command handler for a window, replacing any earlier one.
    ///
    /// - Parameters:
    ///   - window: The window whose key events should become commands.
    ///   - perform: Runs a command and returns `true` if it was handled. Unhandled keys go on to the window as usual.
    func register(_ window: NSWindow, perform: @escaping @MainActor (CommandID) -> Bool) {
        handlers.setObject(Handler(perform), forKey: window)
    }

    /// Starts watching key-down events; calling it again does nothing.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors are delivered on the main thread.
            let consumed = MainActor.assumeIsolated { KeyRouter.shared.handle(event) }
            return consumed ? nil : event
        }
    }

    /// Turns a key-down event into a command, or into part of a pending multi-key sequence.
    ///
    /// - Parameter event: A key-down event from the local monitor.
    /// - Returns: `true` if the event was used and shouldn't propagate.
    private func handle(_ event: NSEvent) -> Bool {
        // Esc leaves a multi-line editor (e.g. the comment box) so vim keys work again.
        // Text views would otherwise treat it as "complete word".
        if let window = event.window, handlers.object(forKey: window) != nil,
            let textView = window.firstResponder as? NSTextView, textView.isEditable, !textView.isFieldEditor,
            KeyChord(event: event) == KeyChord(.escape)
        {
            pending = []
            window.makeFirstResponder(nil)
            return true
        }

        guard let window = event.window, let handler = handlers.object(forKey: window),
            !Self.isTyping(in: window),
            let chord = KeyChord(event: event), !chord.modifiers.contains(.command)
        else {
            pending = []
            return false
        }

        if !pending.isEmpty, Date.now.timeIntervalSince(pendingSince) > Self.sequenceTimeout {
            pending = []
        }
        // Esc cancels a half-typed sequence without running anything.
        if !pending.isEmpty, chord == KeyChord(.escape) {
            pending = []
            return true
        }

        let keymap = ConfigStore.shared.keymap
        var sequence = pending + [chord]
        var match = keymap.match(sequence)
        if match == .none, !pending.isEmpty {
            // Abandoned a sequence; the new key may start or be its own binding.
            sequence = [chord]
            match = keymap.match(sequence)
        }

        switch match {
        case let .command(command):
            pending = []
            let handled = handler.perform(command)
            keyLog.debug(
                "\(Keymap.format(sequence), privacy: .public) → \(command.rawValue, privacy: .public) (\(handled ? "handled" : "not handled here", privacy: .public))"
            )
            return handled
        case .prefix:
            pending = sequence
            pendingSince = .now
            return true
        case .none:
            pending = []
            return false
        }
    }

    /// Whether keystrokes in the window are going into editable text, so they shouldn't be treated as commands.
    private static func isTyping(in window: NSWindow) -> Bool {
        switch window.firstResponder {
        case let textView as NSTextView: textView.isEditable  // includes text fields' field editor
        case is NSTextField: true
        default: false
        }
    }
}
