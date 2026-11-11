// The UI scenario runner: drives a debug build of the app through scripted scenarios, for `scripts/check-ui`.
//
// Launched with `MASER_UI_SCENARIO=<name>`, the first main window hands the runner a `MainWindowProbe`, and the runner
// plays the named scenario from `UIScenarios.swift`. It presses keys by posting real key events, so they go through
// `KeyRouter`, the menus and text views just as typed keys do, and it checks the window's state between steps. It
// writes `PASS` or `FAIL: …` to `MASER_UI_RESULT` and exits. GitHub is a fake `gh` (see `Sources/fake-gh`) that
// replays recordings; scenarios can override its answers and read the commands it was sent. Only debug builds have
// any of this.

import SwiftUI

#if DEBUG
    import AppKit
    import MaserCore

    /// What a scenario can see of a main window besides its `MainWindowState`: the view's own state.
    @MainActor
    struct MainWindowProbe {
        /// The window's state.
        let state: MainWindowState
        /// The PRs selected in the queue.
        let selection: () -> Set<PullRequest.ID>
        /// The queue's sections as shown, after removing repeats and applying the filter.
        let sections: () -> [QueueSection]
    }

    /// A failed check or a timeout in a scenario.
    struct UIScenarioFailure: Error, CustomStringConvertible {
        /// What went wrong.
        let description: String
    }

    /// A named, scripted run through the UI.
    @MainActor
    struct UIScenario {
        /// The name used in `MASER_UI_SCENARIO` and in `UI:` references in docs/design.
        let name: String
        /// The requirement IDs it verifies, then a colon and what it checks, like a test's display name.
        let title: String
        /// The steps.
        let run: @MainActor (UIScenarioDriver) async throws -> Void

        /// Declares a scenario.
        ///
        /// - Parameters:
        ///   - name: The name, in kebab case.
        ///   - title: The IDs it verifies and what it checks, such as `"REQ-WIN-003: Return gives the review the keys"`.
        ///   - run: The steps.
        init(_ name: String, _ title: String, run: @escaping @MainActor (UIScenarioDriver) async throws -> Void) {
            self.name = name
            self.title = title
            self.run = run
        }
    }

    /// Starts the scenario named in the environment, once per launch.
    @MainActor
    enum UIScenarioRunner {
        /// Whether a scenario has started, so a second main window doesn't start another.
        private static var started = false

        /// Runs the scenario named by `MASER_UI_SCENARIO`, if any, then exits the app.
        ///
        /// Does nothing when the variable isn't set, so normal debug runs are unaffected.
        ///
        /// - Parameter probe: The first main window's state.
        static func runIfRequested(_ probe: MainWindowProbe) async {
            let environment = ProcessInfo.processInfo.environment
            guard let name = environment["MASER_UI_SCENARIO"], !started else { return }
            started = true
            let resultPath = environment["MASER_UI_RESULT"]
            let outcome: String
            do {
                outcome = try await run(name, probe: probe)
            } catch {
                outcome = "FAIL: \(error)"
            }
            UIScenarioDriver.say(outcome)
            if let resultPath { try? Data((outcome + "\n").utf8).write(to: URL(filePath: resultPath)) }
            // Exit rather than quit, so nothing is saved for the next launch to restore.
            exit(outcome == "PASS" ? 0 : 1)
        }

        /// Sets up the window and runs a scenario.
        ///
        /// - Parameters:
        ///   - name: The scenario's name.
        ///   - probe: The main window's state.
        /// - Returns: `PASS`.
        /// - Throws: `UIScenarioFailure` if the scenario is unknown, the app isn't using the fake `gh`, or a step fails.
        private static func run(_ name: String, probe: MainWindowProbe) async throws -> String {
            guard let scenario = UIScenarios.all.first(where: { $0.name == name }) else {
                throw UIScenarioFailure(description: "no scenario named \"\(name)\"")
            }
            // Never let a scenario reach real GitHub: its keys can post comments.
            guard ConfigStore.shared.settings.ghPath?.hasSuffix("/fake-gh") == true else {
                throw UIScenarioFailure(description: "config.toml must set [github] gh to fake-gh")
            }
            guard let window = MainWindows.shared.window(for: probe.state) else {
                throw UIScenarioFailure(description: "the main window isn't registered")
            }
            let driver = UIScenarioDriver(window: window, probe: probe)
            UIScenarioDriver.say("scenario \(scenario.name): \(scenario.title)")
            // Menu items and shortcuts that act on the focused window need it to be key, as it is for a user. macOS
            // only activates an app that asks if the frontmost app gives way, so scripts/check-ui also activates it.
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try await driver.waitUntil("the app is active with the window key", timeout: .seconds(15)) {
                if NSApp.isActive, !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
                return NSApp.isActive && window.isKeyWindow
            }
            try await driver.waitUntil("the queue loads", timeout: .seconds(20)) {
                ReviewQueue.shared.sections != nil && !ReviewQueue.shared.isLoading
            }
            try await scenario.run(driver)
            return "PASS"
        }
    }

    /// What a scenario uses to press keys, wait for the app and check its state.
    @MainActor
    final class UIScenarioDriver {
        /// The main window under test.
        let window: NSWindow
        /// The window's state.
        let probe: MainWindowProbe

        /// Creates a driver for a main window.
        ///
        /// - Parameters:
        ///   - window: The window.
        ///   - probe: Its state.
        init(window: NSWindow, probe: MainWindowProbe) {
            self.window = window
            self.probe = probe
        }

        /// The window's state.
        var state: MainWindowState { probe.state }
        /// The open PR's review, if any.
        var review: ReviewModel? { probe.state.openReview }
        /// The PRs in the queue as shown, in order.
        var queuePRs: [PullRequest] { probe.sections().flatMap { $0.prs ?? [] } }
        /// The numbers of the selected PRs, in queue order.
        var selectedNumbers: [Int] {
            let selection = probe.selection()
            return queuePRs.filter { selection.contains($0.id) }.map(\.number)
        }

        /// Writes a line to standard error, which `scripts/check-ui` keeps as the scenario's log.
        ///
        /// - Parameter text: The line.
        static func say(_ text: String) {
            FileHandle.standardError.write(Data((text + "\n").utf8))
        }

        /// Logs a step of the scenario.
        ///
        /// - Parameter text: What the step does or found.
        func step(_ text: String) {
            Self.say("  \(text)")
        }

        // MARK: - Keys

        /// Presses keys, written the way `config.toml` writes bindings, then lets the app handle them.
        ///
        /// Each chord is posted as a key-down event to the window, so it reaches `KeyRouter`, the menus and the
        /// focused view like a real keystroke.
        ///
        /// - Parameter keys: A sequence such as `"j"`, `"g f"`, `"cmd+0"` or `"shift+space"`.
        /// - Throws: `UIScenarioFailure` if the sequence doesn't parse.
        func press(_ keys: String) async throws {
            let chords: [KeyChord]
            do {
                chords = try KeyBindingParser.parseSequence(keys)
            } catch {
                throw UIScenarioFailure(description: "can't press \"\(keys)\": \(error)")
            }
            for chord in chords { post(chord) }
            await settle()
        }

        /// Types text into whatever has keyboard focus, one key event per character.
        ///
        /// - Parameter text: The text; newlines are typed as Return.
        func type(_ text: String) async {
            for character in text {
                post(character == "\n" ? KeyChord(.enter) : KeyChord(character))
            }
            await settle()
        }

        /// Posts one chord as a key-down event to the window, or to its sheet if one is showing, as typing would.
        ///
        /// - Parameter chord: The chord.
        private func post(_ chord: KeyChord) {
            var flags: NSEvent.ModifierFlags = []
            if chord.modifiers.contains(.command) { flags.insert(.command) }
            if chord.modifiers.contains(.option) { flags.insert(.option) }
            if chord.modifiers.contains(.control) { flags.insert(.control) }
            if chord.modifiers.contains(.shift) { flags.insert(.shift) }
            let characters: String
            let keyCode: UInt16
            switch chord.key {
            case let .character(character):
                characters = String(character)
                if character.isUppercase { flags.insert(.shift) }
                keyCode = Self.keyCodes[Character(character.lowercased())] ?? 0
            case let .named(named):
                (characters, keyCode) = Self.namedKeys[named] ?? ("", 0)
            }
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: (window.attachedSheet ?? window).windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
            else { return }
            NSApp.postEvent(event, atStart: false)
        }

        /// Gives the app time to handle posted events and update its views.
        private func settle() async {
            try? await Task.sleep(for: .milliseconds(120))
        }

        /// Virtual key codes for the US layout's character keys, from Carbon's `kVK_ANSI_*` constants.
        private static let keyCodes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
        ]

        /// The characters and virtual key code each named key's events carry; `KeyChord(event:)` reads the code.
        private static let namedKeys: [KeyChord.NamedKey: (String, UInt16)] = [
            .enter: ("\r", 36), .tab: ("\t", 48), .space: (" ", 49), .escape: ("\u{1b}", 53),
            .backspace: ("\u{7f}", 51), .delete: (functionKey(NSDeleteFunctionKey), 117),
            .left: (functionKey(NSLeftArrowFunctionKey), 123),
            .right: (functionKey(NSRightArrowFunctionKey), 124),
            .down: (functionKey(NSDownArrowFunctionKey), 125),
            .up: (functionKey(NSUpArrowFunctionKey), 126),
            .pageUp: (functionKey(NSPageUpFunctionKey), 116),
            .pageDown: (functionKey(NSPageDownFunctionKey), 121),
            .home: (functionKey(NSHomeFunctionKey), 115),
            .end: (functionKey(NSEndFunctionKey), 119),
        ]

        /// The string a function key's events carry, such as the down arrow's.
        ///
        /// - Parameter code: The key's `NS…FunctionKey` constant, a private-use UTF-16 code unit.
        /// - Returns: The one-character string.
        private static func functionKey(_ code: Int) -> String {
            String(utf16CodeUnits: [UInt16(code)], count: 1)
        }

        // MARK: - Waiting and checking

        /// Waits for a condition, checking it every 50 ms.
        ///
        /// - Parameters:
        ///   - what: What's awaited, for the failure message.
        ///   - timeout: How long to wait.
        ///   - condition: The condition.
        /// - Throws: `UIScenarioFailure` if the condition is still false after `timeout`.
        func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + timeout
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    throw UIScenarioFailure(description: "timed out after \(timeout) waiting until \(what) (\(summary))")
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            step("✓ \(what)")
        }

        /// Checks a condition now.
        ///
        /// - Parameters:
        ///   - condition: The condition.
        ///   - what: What it means, for the log and the failure message.
        ///   - detail: The state to report if it fails.
        /// - Throws: `UIScenarioFailure` if the condition is false.
        func expect(_ condition: Bool, _ what: String, _ detail: @autoclosure () -> String = "") throws {
            guard condition else {
                let detail = detail()
                throw UIScenarioFailure(description: "expected \(what)" + (detail.isEmpty ? "" : " (\(detail))"))
            }
            step("✓ \(what)")
        }

        /// Waits a fixed time, for checks that something stays true.
        ///
        /// - Parameter duration: How long.
        func pause(_ duration: Duration) async {
            try? await Task.sleep(for: duration)
        }

        // MARK: - Focus

        /// What has keyboard focus in the window, in the terms scenarios check.
        enum Responder: Equatable, CustomStringConvertible {
            /// A multi-line editor, such as a comment box.
            case editor
            /// A single-line text field, such as the queue's filter.
            case textField
            /// The queue's list.
            case list
            /// Anything else, by class name, or `nil` for none.
            case other(String?)

            var description: String {
                switch self {
                case .editor: "editor"
                case .textField: "text field"
                case .list: "list"
                case let .other(name): name ?? "nothing"
                }
            }
        }

        /// What has keyboard focus in the window.
        var responder: Responder {
            switch window.firstResponder {
            case let textView as NSTextView where textView.isFieldEditor: .textField
            case let textView as NSTextView where textView.isEditable: .editor
            case is NSTableView: .list
            case let other: .other(other.map { String(describing: Swift.type(of: $0)) })
            }
        }

        /// A one-line summary of the window's state, for logs and failure messages.
        var summary: String {
            let review = review.map { "open=#\($0.pr.number) tab=\($0.tab.rawValue) file=\($0.selectedPath ?? "-")" }
            return [
                review ?? "open=none", "queueKeys=\(state.queueHasKeys)",
                "sidebar=\(state.columnVisibility == .detailOnly ? "hidden" : "shown")",
                "selected=\(selectedNumbers.map { "#\($0)" })", "focus=\(responder)",
                "key=\(window.isKeyWindow) active=\(NSApp.isActive)",
            ].joined(separator: " ")
        }

        // MARK: - Opening PRs

        /// Opens a PR from the queue with keys, as the user would: ⌘0, `g g`, `j` to it, then Return.
        ///
        /// - Parameter number: The PR's number; it must be in the queue.
        /// - Throws: `UIScenarioFailure` if it isn't in the queue or its review doesn't load.
        func openFromQueue(_ number: Int) async throws {
            guard let index = queuePRs.firstIndex(where: { $0.number == number }) else {
                throw UIScenarioFailure(description: "#\(number) isn't in the queue")
            }
            try await press("cmd+0")
            try await press("g g")
            for _ in 0..<index { try await press("j") }
            try await press("enter")
            try await waitUntil("#\(number) opens", timeout: .seconds(15)) {
                review?.pr.number == number && review?.overview != nil
            }
        }

        // MARK: - Fake gh

        /// The state directory of the fake `gh`, from `FAKE_GH_STATE`.
        private var ghState: URL? {
            ProcessInfo.processInfo.environment["FAKE_GH_STATE"].map { URL(filePath: $0) }
        }

        /// A `gh` command the app ran, from the log the fake `gh` keeps.
        struct GHCall: Decodable {
            /// The arguments.
            let args: [String]
            /// The exit status returned.
            let status: Int32
            /// Where the answer came from: `override`, `recording`, `recorded` or `missing`.
            let source: String
        }

        /// Every `gh` command run so far, in order.
        var ghCalls: [GHCall] {
            guard let url = ghState?.appending(path: "calls.jsonl"), let text = try? String(contentsOf: url, encoding: .utf8)
            else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(GHCall.self, from: Data($0.utf8)) }
        }

        /// One answer the fake `gh` gives instead of its recordings.
        struct GHOverride: Encodable {
            /// Strings that must each appear in some argument.
            let match: [String]
            /// The exit status.
            let status: Int32
            /// Standard output.
            let stdout: String?
            /// Standard error.
            let stderr: String?
        }

        /// Replaces the overrides of the fake `gh`; later commands that match one get its answer.
        ///
        /// - Parameter overrides: The overrides, checked in order.
        /// - Throws: `UIScenarioFailure` if `FAKE_GH_STATE` isn't set, or a file error.
        func overrideGH(_ overrides: [GHOverride]) throws {
            guard let ghState else { throw UIScenarioFailure(description: "FAKE_GH_STATE isn't set") }
            try JSONEncoder().encode(overrides).write(to: ghState.appending(path: "overrides.json"))
        }
    }
    /// The text some views show, by name, recorded only while a UI scenario runs, so scenarios can check wording.
    @MainActor
    enum ShownText {
        /// Whether views record their text: only in a scenario run.
        static let isEnabled = ProcessInfo.processInfo.environment["MASER_UI_SCENARIO"] != nil
        /// The latest text each named view showed.
        static var values: [String: String] = [:]
    }

#endif

// Outside `#if DEBUG` so views can call it; release builds return the view unchanged.
extension View {
    /// Records the text this view shows in `ShownText` while a UI scenario runs; does nothing otherwise.
    ///
    /// - Parameters:
    ///   - name: What the text is, such as `comment-button`.
    ///   - text: The text the view shows.
    /// - Returns: The view, recording its text when enabled.
    @ViewBuilder
    func shownText(_ name: String, _ text: String) -> some View {
        #if DEBUG
            if ShownText.isEnabled {
                onChange(of: text, initial: true) { _, text in ShownText.values[name] = text }
            } else {
                self
            }
        #else
            self
        #endif
    }
}
