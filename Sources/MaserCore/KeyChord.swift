// Keystrokes as the keymap sees them, and the parser for their `config.toml` syntax.
//
// `KeyChord` is one key plus modifiers, normalized so a binding matches regardless of how it was written or typed.
// `KeyBindingParser` reads strings such as `"g g"` or `"cmd+opt+down"` into chords, with error messages meant for
// the user editing their config.

/// One keystroke: a key plus modifiers.
///
/// Character keys carry their shifted form instead of a shift modifier: shift+j is `J`, shift+/ is `?`.
/// That matches what the keyboard produces, so bindings don't depend on the layout. Named keys
/// (arrows, space, …) keep `.shift` as a modifier.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    /// The key part of a chord.
    public enum Key: Hashable, Sendable {
        /// A key that types a character, in its shifted form if shift was held.
        case character(Character)
        /// A key that doesn't type a character, such as an arrow.
        case named(NamedKey)
    }

    /// Keys without a printable character.
    ///
    /// The raw value is the name used in `config.toml`.
    public enum NamedKey: String, CaseIterable, Sendable {
        case up, down, left, right
        case enter, tab, space, escape = "esc", backspace, delete
        case pageUp = "pageup", pageDown = "pagedown", home, end
    }

    /// The modifier keys held with a chord.
    public struct Modifiers: OptionSet, Hashable, Sendable {
        /// The modifier bits.
        public let rawValue: Int
        /// Creates a modifier set from its bits.
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// The control (⌃) key.
        public static let control = Modifiers(rawValue: 1 << 0)
        /// The option (⌥) key.
        public static let option = Modifiers(rawValue: 1 << 1)
        /// The shift (⇧) key; only kept for named keys.
        public static let shift = Modifiers(rawValue: 1 << 2)
        /// The command (⌘) key.
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    /// The key pressed.
    public let key: Key
    /// The modifiers held, never including `.shift` for character keys.
    public let modifiers: Modifiers

    /// Creates a chord, folding shift into character keys.
    ///
    /// With `.shift`, a letter becomes uppercase and other characters are kept as given; either way `.shift` is
    /// dropped from `modifiers`.
    ///
    /// - Parameters:
    ///   - key: The key pressed.
    ///   - modifiers: The modifiers held.
    public init(_ key: Key, modifiers: Modifiers = []) {
        var modifiers = modifiers
        var key = key
        if case let .character(character) = key, modifiers.contains(.shift) {
            // Fold shift into the character for letters; for other characters the caller
            // (e.g. an NSEvent) already reports the shifted character.
            modifiers.remove(.shift)
            key = .character(Character(character.uppercased()))
        }
        self.key = key
        self.modifiers = modifiers
    }

    /// Creates a chord for a character key.
    ///
    /// - Parameters:
    ///   - character: The character typed, e.g. `"J"` for shift+j.
    ///   - modifiers: The modifiers held.
    public init(_ character: Character, modifiers: Modifiers = []) {
        self.init(.character(character), modifiers: modifiers)
    }

    /// Creates a chord for a named key.
    ///
    /// - Parameters:
    ///   - named: The key pressed.
    ///   - modifiers: The modifiers held.
    public init(_ named: NamedKey, modifiers: Modifiers = []) {
        self.init(.named(named), modifiers: modifiers)
    }

    /// Canonical config syntax, e.g. `J`, `?`, `cmd+opt+down`, `cmd+shift+o`.
    ///
    /// This is the form `KeyBindingParser.parseChord(_:)` accepts, so the keymap template can show defaults with it.
    public var description: String {
        let names: [(Modifiers, String)] = [(.command, "cmd"), (.control, "ctrl"), (.option, "opt"), (.shift, "shift")]
        var parts = names.filter { modifiers.contains($0.0) }.map(\.1)
        let key: String
        switch self.key {
        case let .character(character) where character.isUppercase && !modifiers.isEmpty:
            // "cmd+shift+o" reads better than "cmd+O" alongside other modifiers.
            parts.append("shift")
            key = character.lowercased()
        case let .character(character):
            key = String(character)
        case let .named(named):
            key = named.rawValue
        }
        return (parts + [key]).joined(separator: "+")
    }

    /// Menu-style symbols, e.g. `⌃⌥⌘↓`.
    public var symbols: String {
        let names: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let prefix = names.filter { modifiers.contains($0.0) }.map(\.1).joined()
        let key =
            switch key {
            case let .character(character) where character == " ": "Space"
            // Menus show letters in uppercase; a shifted letter gets an explicit ⇧.
            case let .character(character) where character.isUppercase: "⇧" + String(character)
            case let .character(character): String(character).uppercased()
            case .named(.up): "↑"
            case .named(.down): "↓"
            case .named(.left): "←"
            case .named(.right): "→"
            case .named(.enter): "↩"
            case .named(.tab): "⇥"
            case .named(.space): "Space"
            case .named(.escape): "⎋"
            case .named(.backspace): "⌫"
            case .named(.delete): "⌦"
            case .named(.pageUp): "⇞"
            case .named(.pageDown): "⇟"
            case .named(.home): "↖"
            case .named(.end): "↘"
            }
        return prefix + key
    }
}

/// A problem with a key binding in `config.toml`, worded for the user.
public struct KeyBindingError: Error, Equatable, CustomStringConvertible {
    /// The message to show, e.g. `unknown modifier "super" in "super+j" (use ctrl, opt, shift or cmd)`.
    public let description: String
}

/// Parses key bindings written in `config.toml` syntax.
public enum KeyBindingParser {
    /// Accepted modifier names, lowercased, including common synonyms.
    static let modifierNames: [String: KeyChord.Modifiers] = [
        "ctrl": .control, "control": .control,
        "opt": .option, "option": .option, "alt": .option,
        "shift": .shift,
        "cmd": .command, "command": .command,
    ]

    /// Alternative spellings accepted for named keys, beyond their raw values.
    static let keyAliases: [String: KeyChord.NamedKey] = [
        "return": .enter, "escape": .escape, "arrowup": .up, "arrowdown": .down,
        "arrowleft": .left, "arrowright": .right, "pgup": .pageUp, "pgdown": .pageDown,
    ]

    /// Parses a space-separated key sequence, e.g. `"g g"` or `"ctrl+d"`.
    ///
    /// - Parameter text: The binding as written in the config.
    /// - Returns: One chord per whitespace-separated token.
    /// - Throws: `KeyBindingError` if the text is empty or any chord is invalid.
    public static func parseSequence(_ text: String) throws(KeyBindingError) -> [KeyChord] {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { throw KeyBindingError(description: "empty key binding") }
        return try tokens.map { token throws(KeyBindingError) in try parseChord(String(token)) }
    }

    /// Parses one chord, e.g. `j`, `J`, `?`, `ctrl+d`, `cmd+opt+down`, `ctrl++`.
    ///
    /// Modifiers and named keys are case-insensitive. A single character is taken literally, so `+` alone is the
    /// plus key.
    ///
    /// - Parameter token: One chord, without spaces.
    /// - Returns: The chord.
    /// - Throws: `KeyBindingError` for an unknown modifier or key name, or for shift with a non-letter character,
    ///   which must be written as the shifted character instead.
    public static func parseChord(_ token: String) throws(KeyBindingError) -> KeyChord {
        if token.count == 1 { return KeyChord(Character(token)) }

        let keyPart: String
        let modifierParts: [Substring]
        if token.hasSuffix("++") {
            keyPart = "+"
            modifierParts = token.dropLast(2).split(separator: "+", omittingEmptySubsequences: false)
        } else {
            let parts = token.split(separator: "+", omittingEmptySubsequences: false)
            // Splitting a non-empty string without omitting empties always yields at least one part.
            keyPart = String(parts.last!)
            modifierParts = parts.dropLast()
        }

        var modifiers: KeyChord.Modifiers = []
        for part in modifierParts {
            guard let modifier = modifierNames[part.lowercased()] else {
                throw KeyBindingError(description: "unknown modifier \"\(part)\" in \"\(token)\" (use ctrl, opt, shift or cmd)")
            }
            modifiers.insert(modifier)
        }

        if keyPart.count == 1 {
            let character = Character(keyPart)
            // KeyChord can't fold shift into a non-letter, since the shifted character depends on the layout.
            if modifiers.contains(.shift), !character.isLetter {
                throw KeyBindingError(
                    description: "\"\(token)\": write the shifted character itself (e.g. \"?\" rather than \"shift+/\")")
            }
            return KeyChord(character, modifiers: modifiers)
        }
        let name = keyPart.lowercased()
        guard let named = KeyChord.NamedKey(rawValue: name) ?? keyAliases[name] else {
            let known = KeyChord.NamedKey.allCases.map(\.rawValue).joined(separator: ", ")
            throw KeyBindingError(description: "unknown key \"\(keyPart)\" in \"\(token)\" (named keys: \(known))")
        }
        return KeyChord(named, modifiers: modifiers)
    }
}
