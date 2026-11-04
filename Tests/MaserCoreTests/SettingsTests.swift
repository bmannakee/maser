// Tests for the non-key settings in `config.toml`: the `[diff]`, `[github]` and `[queue]` tables.

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
        // Uncomment every setting line, including the multi-line searches example.
        let uncommented = Keymap.template.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let settingLines = ["# view", "# gh", "# sections", "# searches", "#   {", "# ]"]
            return settingLines.contains(where: line.hasPrefix) ? String(line.dropFirst(2)) : String(line)
        }.joined(separator: "\n")
        let result = try Settings.load(toml: uncommented)
        #expect(result.problems.isEmpty)
        #expect(result.settings.queueSearches.count == 5)
    }

    /// Picks and orders built-in sections, appends custom searches, and reports bad entries and repeated names.
    @Test func readsQueue() throws {
        let result = try Settings.load(
            toml: """
                [queue]
                sections = ["yours", "review-requested", "everything"]
                searches = [
                  { name = "maser", query = "repo:bmannakee/maser" },
                  { name = "Yours", query = "author:someone" },
                  { name = "no query" },
                  { name = "Team", query = "team-review-requested:o/t", colour = "red" },
                ]
                refresh = 30
                """)
        #expect(
            result.settings.queueSearches == [
                .yours, .reviewRequested, PullRequestSearch(name: "maser", query: "repo:bmannakee/maser"),
                PullRequestSearch(name: "Team", query: "team-review-requested:o/t"),
            ])
        #expect(
            result.problems == [
                "[queue] unknown setting \"refresh\"",
                "[queue] sections: unknown section \"everything\"; expected \"review-requested\", \"yours\", \"involving\"",
                "[queue] searches[2]: needs both name and query",
                "[queue] searches[3]: unknown setting \"colour\"",
                "[queue] more than one section is named \"Yours\"; using the first",
            ])
    }

    /// Without `sections`, the queue has every built-in; an empty list leaves only the custom searches.
    @Test func queueSectionsDefault() throws {
        #expect(Settings.defaults.queueSearches == [.reviewRequested, .yours, .involving])
        let custom = try Settings.load(toml: "[queue]\nsearches = [{ name = \"a\", query = \"repo:o/a\" }]")
        #expect(custom.settings.queueSearches.map(\.name) == ["Review requested", "Yours", "Involving you", "a"])
        let only = try Settings.load(toml: "[queue]\nsections = []\nsearches = [{ name = \"a\", query = \"repo:o/a\" }]")
        #expect(only.settings.queueSearches.map(\.name) == ["a"])
    }

    @Test func wrongTypeThrows() {
        #expect(throws: (any Error).self) { try Settings.load(toml: "[diff]\nview = 3") }
    }
}
