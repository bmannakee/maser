// Tests for key bindings: parsing chords and sequences, and loading the user's keymap from TOML.
//
// `KeyBindingParserTests` covers the binding syntax (`ctrl+d`, `g g`, named keys). `KeymapTests` covers the default
// keymap, how a config file overrides and unbinds it, the problems it reports, and the commented-out template.

import Testing

@testable import MaserCore

/// Tests for parsing binding strings into `KeyChord`s and sequences.
@Suite struct KeyBindingParserTests {
    /// Parses a single character, including punctuation that's also binding syntax, as a plain chord.
    @Test func characters() throws {
        #expect(try KeyBindingParser.parseChord("j") == KeyChord("j"))
        #expect(try KeyBindingParser.parseChord("J") == KeyChord("J"))
        #expect(try KeyBindingParser.parseChord("?") == KeyChord("?"))
        #expect(try KeyBindingParser.parseChord("+") == KeyChord("+"))
    }

    /// Turns shift plus a letter into the uppercase letter, and rejects shift on a non-letter character.
    @Test func shiftFoldsIntoLetters() throws {
        #expect(try KeyBindingParser.parseChord("shift+j") == KeyChord("J"))
        #expect(KeyChord("j", modifiers: [.command, .shift]) == KeyChord("J", modifiers: .command))
        #expect(throws: KeyBindingError.self) { try KeyBindingParser.parseChord("shift+/") }
    }

    /// Accepts modifier and key names case-insensitively, with aliases like `opt` and `return`, and `ctrl++` for plus.
    @Test func modifiersAndNamedKeys() throws {
        #expect(try KeyBindingParser.parseChord("ctrl+d") == KeyChord("d", modifiers: .control))
        #expect(try KeyBindingParser.parseChord("CMD+Opt+Down") == KeyChord(.down, modifiers: [.command, .option]))
        #expect(try KeyBindingParser.parseChord("shift+down") == KeyChord(.down, modifiers: .shift))
        #expect(try KeyBindingParser.parseChord("return") == KeyChord(.enter))
        #expect(try KeyBindingParser.parseChord("ctrl++") == KeyChord("+", modifiers: .control))
    }

    /// Rejects unknown modifiers, unknown key names and blank sequences.
    @Test func errors() {
        #expect(throws: KeyBindingError.self) { try KeyBindingParser.parseChord("hyper+j") }
        #expect(throws: KeyBindingError.self) { try KeyBindingParser.parseChord("ctrl+banana") }
        #expect(throws: KeyBindingError.self) { try KeyBindingParser.parseSequence("   ") }
    }

    /// Splits a sequence on whitespace, ignoring extra spaces.
    @Test func sequences() throws {
        #expect(try KeyBindingParser.parseSequence("g g") == [KeyChord("g"), KeyChord("g")])
        #expect(try KeyBindingParser.parseSequence(" ctrl+w  j ") == [KeyChord("w", modifiers: .control), KeyChord("j")])
    }

    /// Parses a chord's `description` back to the same chord, and renders `symbols` in macOS menu order.
    @Test func descriptionRoundTrips() throws {
        let chords = [
            KeyChord("j"), KeyChord("J"), KeyChord("?"), KeyChord("+", modifiers: .control),
            KeyChord(.down, modifiers: [.command, .option, .shift]), KeyChord(",", modifiers: .command),
        ]
        for chord in chords {
            #expect(try KeyBindingParser.parseChord(chord.description) == chord)
        }
        #expect(KeyChord(.down, modifiers: [.command, .option]).symbols == "⌥⌘↓")
        #expect(KeyChord("J", modifiers: .command).symbols == "⌘⇧J")
        #expect(KeyChord("j").symbols == "J")
    }
}

/// Tests for the default keymap and for loading overrides from the TOML config.
@Suite struct KeymapTests {
    /// Matches single keys and `g` sequences to commands, reports a bare `g` as a prefix, and has no shadowed bindings.
    @Test func defaultsMatchSequences() {
        let keymap = Keymap.defaults
        #expect(keymap.match([KeyChord("j")]) == .command(.cursorDown))
        #expect(keymap.match([KeyChord("]")]) == .command(.nextFile))
        #expect(keymap.match([KeyChord("[")]) == .command(.previousFile))
        #expect(keymap.match([KeyChord("}")]) == .command(.nextHunk))
        #expect(keymap.match([KeyChord(.escape)]) == .command(.cancel))
        #expect(keymap.match([KeyChord("z")]) == .prefix)
        #expect(keymap.match([KeyChord("z"), KeyChord("a")]) == .command(.toggleFullFile))
        #expect(keymap.match([KeyChord("z"), KeyChord("R")]) == .command(.expandAllFiles))
        #expect(keymap.match([KeyChord("z"), KeyChord("M")]) == .command(.collapseAllFiles))
        #expect(keymap.match([KeyChord("g")]) == .prefix)
        #expect(keymap.match([KeyChord("g"), KeyChord("f")]) == .command(.showFiles))
        #expect(keymap.match([KeyChord("g"), KeyChord("x")]) == .none)
        #expect(keymap.match([KeyChord("x")]) == .none)
        #expect(keymap.shadowingProblems().isEmpty)
    }

    @Test func defaultScrollBindings() throws {
        let keymap = Keymap.defaults
        #expect(keymap.match(try KeyBindingParser.parseSequence("ctrl+d")) == .command(.halfPageDown))
        #expect(keymap.match(try KeyBindingParser.parseSequence("ctrl+u")) == .command(.halfPageUp))
        #expect(keymap.match(try KeyBindingParser.parseSequence("space")) == .command(.pageDown))
        #expect(keymap.match(try KeyBindingParser.parseSequence("shift+space")) == .command(.pageUp))
        #expect(keymap.match(try KeyBindingParser.parseSequence("g g")) == .command(.scrollToTop))
        #expect(keymap.match(try KeyBindingParser.parseSequence("G")) == .command(.scrollToBottom))
    }

    @Test func emptyConfigIsDefaults() throws {
        let result = try Keymap.load(toml: "")
        #expect(result.keymap == .defaults)
        #expect(result.problems.isEmpty)
    }

    /// Replaces a command's default bindings with the configured ones, unbinds with `"none"`, and leaves unmentioned
    /// commands alone.
    @Test func overridesAndUnbinds() throws {
        let result = try Keymap.load(
            toml: """
                [keys]
                next-file = "ctrl+opt+j"
                refresh = "none"

                [keys.normal]
                next-file = ["j", "down"]
                previous-file = "none"
                show-files = "g g"
                """)
        #expect(result.problems.isEmpty)
        let keymap = result.keymap
        #expect(keymap.menu[.nextFile] == KeyChord("j", modifiers: [.control, .option]))
        #expect(keymap.menu[.refresh] == nil)
        #expect(keymap.menu[.showFiles] == Keymap.defaults.menu[.showFiles])  // untouched
        #expect(keymap.match([KeyChord(.down)]) == .command(.nextFile))
        #expect(keymap.match([KeyChord("["), KeyChord("f")]) == .none)
        #expect(keymap.match([KeyChord("g"), KeyChord("g")]) == .command(.showFiles))
        #expect(keymap.match([KeyChord("g"), KeyChord("f")]) == .none)  // replaced, not added
    }

    /// A configured key is removed from whichever command had it by default, in both the menu and normal mode.
    @Test func userBindingStealsKeysFromDefaults() throws {
        let keymap = try Keymap.load(
            toml: """
                [keys]
                refresh = "cmd+o"
                [keys.normal]
                refresh = "j"
                """
        ).keymap
        #expect(keymap.menu[.refresh] == KeyChord("o", modifiers: .command))
        #expect(keymap.menu[.openPullRequest] == nil)
        #expect(keymap.match([KeyChord("j")]) == .command(.refresh))
        #expect(keymap.normal[.cursorDown] == nil)
    }

    /// Reports each invalid binding (unknown command or key, menu shortcuts without cmd or with a sequence, cmd in normal
    /// mode, duplicate keys) while still applying the valid ones.
    @Test func reportsProblemsButKeepsTheRest() throws {
        let result = try Keymap.load(
            toml: """
                [keys]
                frobnicate = "cmd+f"
                next-file = "j"
                previous-file = "g g"
                show-files = "cmd+3"

                [keys.normal]
                refresh = ["ctrl+banana", "R"]
                open-on-github = "cmd+g"
                next-thread = "x"
                previous-thread = "x"
                """)
        let problems = result.problems.joined(separator: "\n")
        #expect(problems.contains("unknown command \"frobnicate\""))
        #expect(problems.contains("next-file = \"j\": menu shortcuts need cmd"))
        #expect(problems.contains("previous-file = \"g g\": menu shortcuts are a single chord"))
        #expect(problems.contains("unknown key \"banana\""))
        #expect(problems.contains("cmd shortcuts belong in [keys]"))
        #expect(problems.contains("\"x\" is bound to both next-thread and previous-thread"))
        #expect(result.problems.count == 6)

        let keymap = result.keymap
        #expect(keymap.menu[.showFiles] == KeyChord("3", modifiers: .command))
        #expect(keymap.match([KeyChord("R")]) == .command(.refresh))
        #expect(keymap.match([KeyChord("x")]) == .command(.previousThread))
    }

    /// A command whose every key fails to parse keeps its default keys rather than ending up with none.
    @Test func invalidOnlyValueKeepsDefaults() throws {
        let result = try Keymap.load(
            toml: """
                [keys.normal]
                cursor-down = "ctrl+banana"
                """)
        #expect(result.problems.count == 1)
        #expect(result.keymap.match([KeyChord("j")]) == .command(.cursorDown))
    }

    /// Reports each sequence that a shorter binding makes unreachable, and keeps the shorter binding.
    @Test func reportsShadowedSequences() throws {
        let result = try Keymap.load(
            toml: """
                [keys.normal]
                refresh = "g"
                """)
        #expect(result.problems.count == 4)  // hides "g o", "g f", "g g" and "g p"
        #expect(result.problems[0].contains("\"g\" (refresh) hides \"g f\" (show-files)"))
        #expect(result.keymap.match([KeyChord("g")]) == .command(.refresh))
    }

    /// Throws for malformed TOML and for a binding that isn't a string or array of strings.
    @Test func invalidTOMLThrows() {
        #expect(throws: (any Error).self) { try Keymap.load(toml: "[keys\nnext-file = ") }
        #expect(throws: (any Error).self) { try Keymap.load(toml: "[keys]\nnext-file = 3") }
    }

    /// The config template lists every default binding, commented out, so loading it as-is or uncommented gives the
    /// defaults.
    @Test func templateParsesAsDefaults() throws {
        let template = Keymap.template
        #expect(template.contains("# next-file = \"cmd+opt+down\""))
        #expect(template.contains("# show-overview = \"g o\""))
        // Fully commented out, so loading it changes nothing.
        let result = try Keymap.load(toml: template)
        #expect(result.keymap == .defaults)
        #expect(result.problems.isEmpty)

        // Uncommenting every line also reproduces the defaults exactly.
        let uncommented = template.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let isBinding = CommandID.allCases.contains { line.hasPrefix("# \($0.rawValue) = ") }
            return isBinding ? String(line.dropFirst(2)) : String(line)
        }.joined(separator: "\n")
        let explicit = try Keymap.load(toml: uncommented)
        #expect(explicit.problems.isEmpty)
        #expect(explicit.keymap == .defaults)
    }
}
