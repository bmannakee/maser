// Tests for the non-key settings in `config.toml`: the `[diff]` and `[github]` tables.

import Testing

@testable import MaserCore

/// Tests for `Settings.load(toml:)`.
@Suite struct SettingsTests {
    @Test func emptyConfigIsDefaults() throws {
        let result = try Settings.load(toml: "")
        #expect(result.settings == .defaults)
        #expect(result.settings.diffView == .hunks)
        #expect(result.problems.isEmpty)
    }

    /// Reads the diff view and the `gh` path, alongside key bindings the settings ignore.
    @Test func readsSettings() throws {
        let result = try Settings.load(
            toml: """
                [keys.normal]
                cursor-down = "j"

                [diff]
                view = "full"

                [github]
                gh = "~/bin/gh"
                """)
        #expect(result.problems.isEmpty)
        #expect(result.settings.diffView == .full)
        #expect(result.settings.ghPath == "~/bin/gh")
    }

    /// Reports unknown values and keys and keeps the defaults for them; a blank `gh` means search as usual.
    @Test func reportsProblems() throws {
        let result = try Settings.load(
            toml: """
                [diff]
                view = "everything"
                colour = "blue"

                [github]
                gh = " "
                """)
        #expect(result.settings == .defaults)
        #expect(
            result.problems == [
                "[diff] unknown setting \"colour\"", "[diff] view = \"everything\": expected \"hunks\" or \"full\"",
            ])
    }

    /// The starter config lists the settings commented out, so it loads as the defaults, and uncommented too.
    @Test func templateHasSettings() throws {
        #expect(Keymap.template.contains("# view = \"hunks\""))
        #expect(try Settings.load(toml: Keymap.template).settings == .defaults)
        let uncommented = Keymap.template.replacingOccurrences(of: "# view = ", with: "view = ")
        #expect(try Settings.load(toml: uncommented).problems.isEmpty)
    }

    @Test func wrongTypeThrows() {
        #expect(throws: (any Error).self) { try Settings.load(toml: "[diff]\nview = 3") }
    }
}
