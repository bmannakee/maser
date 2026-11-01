@testable import MaserCore
import Testing

@Suite struct KeyBindingParserTests {
    @Test func characters() throws {
        #expect(try KeyBindingParser.parseChord("j") == KeyChord("j"))
        #expect(try KeyBindingParser.parseChord("J") == KeyChord("J"))
        #expect(try KeyBindingParser.parseChord("?") == KeyChord("?"))
        #expect(try KeyBindingParser.parseChord("+") == KeyChord("+"))
    }

    @Test func shiftFoldsIntoLetters() throws {
        #expect(try KeyBindingParser.parseChord("shift+j") == KeyChord("J"))
        #expect(KeyChord("j", modifiers: [.command, .shift]) == KeyChord("J", modifiers: .command))
        #expect(throws: KeyBindingError.self) { try KeyBindingParser.parseChord("shift+/") }
    }

    @Test func modifiersAndNamedKeys() throws {
        #expect(try KeyBindingParser.parseChord("ctrl+d") == KeyChord("d", modifiers: .control))
        #expect(try KeyBindingParser.parseChord("CMD+Opt+Down") == KeyChord(.down, modifiers: [.command, .option]))
        #expect(try KeyBindingParser.parseChord("shift+down") == KeyChord(.down, modifiers: .shift))
        #expect(try KeyBindingParser.parseChord("return") == KeyChord(.enter))
        #expect(try KeyBindingParser.parseChord("ctrl++") == KeyChord("+", modifiers: .control))
    }

    @Test func errors() {
        #expect(throws: KeyBindingError.self) { try KeyBindingParser.parseChord("hyper+j") }
        #expect(throws: KeyBindingError.self) { try KeyBindingParser.parseChord("ctrl+banana") }
        #expect(throws: KeyBindingError.self) { try KeyBindingParser.parseSequence("   ") }
    }

    @Test func sequences() throws {
        #expect(try KeyBindingParser.parseSequence("g g") == [KeyChord("g"), KeyChord("g")])
        #expect(try KeyBindingParser.parseSequence(" ctrl+w  j ") == [KeyChord("w", modifiers: .control), KeyChord("j")])
    }

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

@Suite struct KeymapTests {
    @Test func defaultsMatchSequences() {
        let keymap = Keymap.defaults
        #expect(keymap.match([KeyChord("j")]) == .command(.nextFile))
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

    @Test func overridesAndUnbinds() throws {
        let result = try Keymap.load(toml: """
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
        #expect(keymap.menu[.showFiles] == Keymap.defaults.menu[.showFiles]) // untouched
        #expect(keymap.match([KeyChord(.down)]) == .command(.nextFile))
        #expect(keymap.match([KeyChord("k")]) == .none)
        #expect(keymap.match([KeyChord("g"), KeyChord("g")]) == .command(.showFiles))
        #expect(keymap.match([KeyChord("g"), KeyChord("f")]) == .none) // replaced, not added
    }

    @Test func userBindingStealsKeysFromDefaults() throws {
        let keymap = try Keymap.load(toml: """
        [keys]
        refresh = "cmd+o"
        [keys.normal]
        refresh = "j"
        """).keymap
        #expect(keymap.menu[.refresh] == KeyChord("o", modifiers: .command))
        #expect(keymap.menu[.openPullRequest] == nil)
        #expect(keymap.match([KeyChord("j")]) == .command(.refresh))
        #expect(keymap.normal[.nextFile] == nil)
    }

    @Test func reportsProblemsButKeepsTheRest() throws {
        let result = try Keymap.load(toml: """
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

    @Test func reportsShadowedSequences() throws {
        let result = try Keymap.load(toml: """
        [keys.normal]
        refresh = "g"
        """)
        #expect(result.problems.count == 3) // hides "g o", "g f" and "g g"
        #expect(result.problems[0].contains("\"g\" (refresh) hides \"g f\" (show-files)"))
        #expect(result.keymap.match([KeyChord("g")]) == .command(.refresh))
    }

    @Test func invalidTOMLThrows() {
        #expect(throws: (any Error).self) { try Keymap.load(toml: "[keys\nnext-file = ") }
        #expect(throws: (any Error).self) { try Keymap.load(toml: "[keys]\nnext-file = 3") }
    }

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
