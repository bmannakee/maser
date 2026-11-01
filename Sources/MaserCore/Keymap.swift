import Foundation
import TOMLDecoder

/// All key bindings: menu-bar shortcuts plus vim-style "normal mode" keys
/// (active whenever you aren't typing in a text field).
public struct Keymap: Sendable, Equatable {
    public enum Match: Equatable, Sendable {
        case command(CommandID)
        /// The keys so far start a longer binding; wait for more.
        case prefix
        case none
    }

    public private(set) var menu: [CommandID: KeyChord]
    public private(set) var normal: [CommandID: [[KeyChord]]]
    private var normalLookup: [[KeyChord]: CommandID] = [:]
    private var normalPrefixes: Set<[KeyChord]> = []

    public init(menu: [CommandID: KeyChord], normal: [CommandID: [[KeyChord]]]) {
        self.menu = menu
        self.normal = normal.filter { !$0.value.isEmpty }
        for (command, sequences) in self.normal.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for sequence in sequences {
                normalLookup[sequence] = command
                for length in 1..<max(sequence.count, 1) {
                    normalPrefixes.insert(Array(sequence.prefix(length)))
                }
            }
        }
    }

    /// Resolves keys typed so far in normal mode. An exact binding wins over a longer one it prefixes.
    public func match(_ sequence: [KeyChord]) -> Match {
        if let command = normalLookup[sequence] { return .command(command) }
        if normalPrefixes.contains(sequence) { return .prefix }
        return .none
    }

    public static let defaults = Keymap(
        menu: [
            .openPullRequest: KeyChord("o", modifiers: .command),
            .refresh: KeyChord("r", modifiers: .command),
            .openOnGitHub: KeyChord("o", modifiers: [.command, .shift]),
            .showOverview: KeyChord("1", modifiers: .command),
            .showFiles: KeyChord("2", modifiers: .command),
            .toggleComments: KeyChord("0", modifiers: [.command, .option]),
            .nextFile: KeyChord(.down, modifiers: [.command, .option]),
            .previousFile: KeyChord(.up, modifiers: [.command, .option]),
            .nextThread: KeyChord(.down, modifiers: [.command, .control]),
            .previousThread: KeyChord(.up, modifiers: [.command, .control]),
            .comment: KeyChord("c", modifiers: [.command, .option]),
            .submitReview: KeyChord("r", modifiers: [.command, .option]),
            .openConfig: KeyChord(",", modifiers: .command),
            .showKeybindings: KeyChord("/", modifiers: .command),
        ],
        normal: [
            .cursorDown: [[KeyChord("j")]],
            .cursorUp: [[KeyChord("k")]],
            .nextFile: [[KeyChord("]")]],
            .previousFile: [[KeyChord("[")]],
            .nextHunk: [[KeyChord("}")]],
            .previousHunk: [[KeyChord("{")]],
            .selectLines: [[KeyChord("V")]],
            .cancel: [[KeyChord(.escape)]],
            .reply: [[KeyChord("R")]],
            .submitReview: [[KeyChord("S")]],
            .nextThread: [[KeyChord("n")]],
            .previousThread: [[KeyChord("N")]],
            .comment: [[KeyChord("c")]],
            .scrollDown: [[KeyChord("e", modifiers: .control)]],
            .scrollUp: [[KeyChord("y", modifiers: .control)]],
            .halfPageDown: [[KeyChord("d", modifiers: .control)]],
            .halfPageUp: [[KeyChord("u", modifiers: .control)]],
            .pageDown: [[KeyChord("f", modifiers: .control)], [KeyChord(.space)]],
            .pageUp: [[KeyChord("b", modifiers: .control)], [KeyChord(.space, modifiers: .shift)]],
            .scrollToTop: [[KeyChord("g"), KeyChord("g")]],
            .scrollToBottom: [[KeyChord("G")]],
            .showOverview: [[KeyChord("g"), KeyChord("o")]],
            .showFiles: [[KeyChord("g"), KeyChord("f")]],
            .toggleComments: [[KeyChord("i")]],
            .refresh: [[KeyChord("r")]],
            .openOnGitHub: [[KeyChord("o")]],
            .showKeybindings: [[KeyChord("?")]],
        ]
    )
}

// MARK: - Loading config.toml

extension Keymap {
    public struct LoadResult: Sendable {
        public let keymap: Keymap
        /// Non-fatal issues (unknown commands, bad keys, conflicts); the rest of the config still applies.
        public let problems: [String]
    }

    /// Applies a `config.toml`'s `[keys]` and `[keys.normal]` tables on top of the defaults.
    /// Throws only when the file isn't valid TOML or has the wrong shape.
    public static func load(toml: String) throws -> LoadResult {
        let file: ConfigFile
        do {
            file = try TOMLDecoder().decode(ConfigFile.self, from: toml)
        } catch let error as DecodingError {
            throw KeyBindingError(description: describe(error))
        }
        var problems: [String] = []

        // Menu shortcuts: one chord each, and it must include cmd/ctrl/opt.
        var menu = defaults.menu
        var userMenu: [KeyChord: CommandID] = [:]
        for (name, value) in (file.keys?.menu ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let command = CommandID(rawValue: name) else {
                problems.append("[keys] unknown command \"\(name)\"")
                continue
            }
            if isUnbind(value) {
                menu[command] = nil
                continue
            }
            let sequence: [KeyChord]
            do { sequence = try KeyBindingParser.parseSequence(value) } catch {
                problems.append("[keys] \(name): \(error)")
                continue
            }
            guard sequence.count == 1, let chord = sequence.first else {
                problems.append(
                    "[keys] \(name) = \"\(value)\": menu shortcuts are a single chord; put sequences in [keys.normal]")
                continue
            }
            guard !chord.modifiers.isDisjoint(with: [.command, .control, .option]) else {
                problems.append(
                    "[keys] \(name) = \"\(value)\": menu shortcuts need cmd, ctrl or opt; put single keys in [keys.normal]")
                continue
            }
            if let other = userMenu[chord], other != command {
                problems.append("[keys] \(chord) is bound to both \(other.rawValue) and \(name); using \(name)")
                menu[other] = nil
            }
            userMenu[chord] = command
            menu[command] = chord
        }
        // A user binding takes its chord away from whichever default had it.
        for (command, chord) in menu where userMenu[chord].map({ $0 != command }) ?? false {
            menu[command] = nil
        }

        // Normal-mode keys: one or more sequences each, no cmd.
        var normal = defaults.normal
        var userNormal: [[KeyChord]: CommandID] = [:]
        for (name, binding) in (file.keys?.normal ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let command = CommandID(rawValue: name) else {
                problems.append("[keys.normal] unknown command \"\(name)\"")
                continue
            }
            var sequences: [[KeyChord]] = []
            for value in binding.values where !isUnbind(value) {
                do {
                    let sequence = try KeyBindingParser.parseSequence(value)
                    if sequence.contains(where: { $0.modifiers.contains(.command) }) {
                        problems.append("[keys.normal] \(name) = \"\(value)\": cmd shortcuts belong in [keys]")
                        continue
                    }
                    if let other = userNormal[sequence], other != command {
                        problems.append(
                            "[keys.normal] \"\(value)\" is bound to both \(other.rawValue) and \(name); using \(name)")
                        normal[other]?.removeAll { $0 == sequence }
                    }
                    userNormal[sequence] = command
                    sequences.append(sequence)
                } catch {
                    problems.append("[keys.normal] \(name): \(error)")
                }
            }
            normal[command] = sequences
        }
        for command in normal.keys {
            normal[command]?.removeAll { sequence in userNormal[sequence].map { $0 != command } ?? false }
        }

        let keymap = Keymap(menu: menu, normal: normal)
        problems += keymap.shadowingProblems()
        return LoadResult(keymap: keymap, problems: problems)
    }

    /// Bindings that can never fire because a shorter binding is a prefix of them.
    func shadowingProblems() -> [String] {
        normalLookup.keys.sorted { Self.format($0) < Self.format($1) }.compactMap { sequence in
            guard sequence.count > 1 else { return nil }
            for length in 1..<sequence.count {
                let prefix = Array(sequence.prefix(length))
                if let shorter = normalLookup[prefix] {
                    return
                        "[keys.normal] \"\(Self.format(prefix))\" (\(shorter.rawValue)) hides \"\(Self.format(sequence))\" (\(normalLookup[sequence]!.rawValue))"
                }
            }
            return nil
        }
    }

    private static func isUnbind(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "none"
    }

    public static func format(_ sequence: [KeyChord]) -> String {
        sequence.map(\.description).joined(separator: " ")
    }

    private static func describe(_ error: DecodingError) -> String {
        let (context, message): (DecodingError.Context?, String) =
            switch error {
            case let .typeMismatch(type, context): (context, "expected \(type == String.self ? "a string" : "\(type)")")
            case let .valueNotFound(_, context): (context, "missing value")
            case let .keyNotFound(key, context): (context, "missing \"\(key.stringValue)\"")
            case let .dataCorrupted(context):
                (context, context.underlyingError.map { "\(context.debugDescription) (\($0))" } ?? context.debugDescription)
            @unknown default: (nil, "\(error)")
            }
        let path = context?.codingPath.map(\.stringValue).joined(separator: ".") ?? ""
        return path.isEmpty ? message : "\(path): \(message)"
    }

    struct ConfigFile: Decodable {
        let keys: KeysTable?
    }

    /// `[keys]` holds menu shortcuts directly, plus the `[keys.normal]` sub-table.
    struct KeysTable: Decodable {
        var menu: [String: String] = [:]
        var normal: [String: Binding] = [:]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            for key in container.allKeys {
                if key.stringValue == "normal" {
                    normal = try container.decode([String: Binding].self, forKey: key)
                } else {
                    menu[key.stringValue] = try container.decode(String.self, forKey: key)
                }
            }
        }
    }

    /// `"j"` or `["j", "down"]`.
    struct Binding: Decodable {
        let values: [String]

        init(from decoder: any Decoder) throws {
            if let single = try? decoder.singleValueContainer().decode(String.self) {
                values = [single]
                return
            }
            // TOMLDecoder only exposes arrays through unkeyed containers.
            var array = try decoder.unkeyedContainer()
            var values: [String] = []
            while !array.isAtEnd {
                values.append(try array.decode(String.self))
            }
            self.values = values
        }
    }

    struct AnyKey: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }
}

// MARK: - Template

extension Keymap {
    /// A commented-out config listing every command with its default bindings.
    public static var template: String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func rows(_ value: (CommandID) -> String) -> [String] {
            let width = CommandID.allCases.map { $0.rawValue.count + value($0).count }.max()! + 5
            return CommandID.allCases.map { command in
                let assignment = "# \(command.rawValue) = \(value(command))"
                return assignment.padding(toLength: width, withPad: " ", startingAt: 0) + "  # \(command.title)"
            }
        }

        let menuRows = rows { defaults.menu[$0].map { quoted($0.description) } ?? quoted("none") }
        let normalRows = rows { command in
            let sequences = defaults.normal[command] ?? []
            return switch sequences.count {
            case 0: quoted("none")
            case 1: quoted(format(sequences[0]))
            default: "[" + sequences.map { quoted(format($0)) }.joined(separator: ", ") + "]"
            }
        }

        return """
            # Maser config. Saved changes apply immediately.
            # Uncomment a line to change a binding; anything left out keeps its default.

            # Menu-bar shortcuts. Each needs cmd, ctrl or opt, e.g. "cmd+opt+down".
            # Use "none" to remove one.
            [keys]
            \(menuRows.joined(separator: "\n"))

            # Vim-style keys, active whenever you're not typing in a text field.
            #   Characters: "j", "J" (shift+j), "?", "]"
            #   Named keys: \(KeyChord.NamedKey.allCases.map(\.rawValue).joined(separator: ", "))
            #   Modifiers:  "ctrl+d", "opt+j", "shift+down"
            #   Sequences:  "g g" (space-separated keystrokes)
            #   Several:    next-file = ["j", "down"]
            # A binding you set here takes those keys away from any other command.
            [keys.normal]
            \(normalRows.joined(separator: "\n"))

            """
    }
}
