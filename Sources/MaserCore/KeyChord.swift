/// One keystroke: a key plus modifiers.
///
/// Character keys carry their shifted form instead of a shift modifier: shift+j is `J`, shift+/ is `?`.
/// That matches what the keyboard produces, so bindings don't depend on the layout. Named keys
/// (arrows, space, …) keep `.shift` as a modifier.
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public enum Key: Hashable, Sendable {
        case character(Character)
        case named(NamedKey)
    }

    public enum NamedKey: String, CaseIterable, Sendable {
        case up, down, left, right
        case enter, tab, space, escape = "esc", backspace, delete
        case pageUp = "pageup", pageDown = "pagedown", home, end
    }

    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let shift = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public let key: Key
    public let modifiers: Modifiers

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

    public init(_ character: Character, modifiers: Modifiers = []) {
        self.init(.character(character), modifiers: modifiers)
    }

    public init(_ named: NamedKey, modifiers: Modifiers = []) {
        self.init(.named(named), modifiers: modifiers)
    }

    /// Canonical config syntax, e.g. `J`, `?`, `cmd+opt+down`, `cmd+shift+o`.
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
            // Menus show letters in uppercase; a shifted letter gets an explicit ⇧.
            case let .character(character) where character == " ": "Space"
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

public struct KeyBindingError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public enum KeyBindingParser {
    static let modifierNames: [String: KeyChord.Modifiers] = [
        "ctrl": .control, "control": .control,
        "opt": .option, "option": .option, "alt": .option,
        "shift": .shift,
        "cmd": .command, "command": .command,
    ]

    static let keyAliases: [String: KeyChord.NamedKey] = [
        "return": .enter, "escape": .escape, "arrowup": .up, "arrowdown": .down,
        "arrowleft": .left, "arrowright": .right, "pgup": .pageUp, "pgdown": .pageDown,
    ]

    /// Parses a space-separated key sequence, e.g. `"g g"` or `"ctrl+d"`.
    public static func parseSequence(_ text: String) throws(KeyBindingError) -> [KeyChord] {
        let tokens = text.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { throw KeyBindingError(description: "empty key binding") }
        return try tokens.map { token throws(KeyBindingError) in try parseChord(String(token)) }
    }

    /// Parses one chord, e.g. `j`, `J`, `?`, `ctrl+d`, `cmd+opt+down`, `ctrl++`.
    public static func parseChord(_ token: String) throws(KeyBindingError) -> KeyChord {
        if token.count == 1 { return KeyChord(Character(token)) }

        let keyPart: String
        let modifierParts: [Substring]
        if token.hasSuffix("++") {
            keyPart = "+"
            modifierParts = token.dropLast(2).split(separator: "+", omittingEmptySubsequences: false)
        } else {
            let parts = token.split(separator: "+", omittingEmptySubsequences: false)
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
