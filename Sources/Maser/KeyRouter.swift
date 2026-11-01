import AppKit
import MaserCore
import os

private let keyLog = Logger(subsystem: "dev.maser", category: "keys")

/// Vim-style "normal mode": turns plain keystrokes into commands whenever the user isn't
/// typing in a text field. Runs ahead of menu shortcuts; ⌘ chords always go to the menus.
@MainActor
final class KeyRouter {
    static let shared = KeyRouter()

    /// How long to wait for the rest of a multi-key sequence like `g f`.
    static let sequenceTimeout: TimeInterval = 1.5

    final class Handler {
        let perform: @MainActor (CommandID) -> Bool
        init(_ perform: @escaping @MainActor (CommandID) -> Bool) { self.perform = perform }
    }

    private let handlers = NSMapTable<NSWindow, Handler>.weakToStrongObjects()
    private var monitor: Any?
    private var pending: [KeyChord] = []
    private var pendingSince = Date.distantPast

    func register(_ window: NSWindow, perform: @escaping @MainActor (CommandID) -> Bool) {
        handlers.setObject(Handler(perform), forKey: window)
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors are delivered on the main thread.
            let consumed = MainActor.assumeIsolated { KeyRouter.shared.handle(event) }
            return consumed ? nil : event
        }
    }

    /// Returns true if the event was used and shouldn't propagate.
    private func handle(_ event: NSEvent) -> Bool {
        // Esc leaves a multi-line editor (e.g. the comment box) so vim keys work again.
        // Text views would otherwise treat it as "complete word".
        if let window = event.window, handlers.object(forKey: window) != nil,
           let textView = window.firstResponder as? NSTextView, textView.isEditable, !textView.isFieldEditor,
           KeyChord(event: event) == KeyChord(.escape) {
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
            keyLog.debug("\(Keymap.format(sequence), privacy: .public) → \(command.rawValue, privacy: .public) (\(handled ? "handled" : "not handled here", privacy: .public))")
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

    private static func isTyping(in window: NSWindow) -> Bool {
        switch window.firstResponder {
        case let textView as NSTextView: textView.isEditable // includes text fields' field editor
        case is NSTextField: true
        default: false
        }
    }
}
