// The non-key settings in `config.toml`.
//
// Alongside the key bindings (see `Keymap`), the config file has a few plain settings: how the Files tab shows a file
// at first, where `gh` is when the app can't find it, and the review queue's sections. `Settings.load(toml:)` reads them, falling back to defaults
// and reporting problems the same way the keymap does.

import Foundation
import TOMLDecoder

/// The settings from `config.toml` other than key bindings.
public struct Settings: Equatable, Sendable {
    /// How the Files tab shows a file's diff.
    public enum DiffView: String, CaseIterable, Sendable {
        /// Only the changed hunks, with a few lines of context, as GitHub's diff has them.
        case hunks
        /// The whole file, with the changes in place.
        case full
    }

    /// How files open in the Files tab; `[diff] view` in the config.
    public var diffView = DiffView.hunks
    /// The path to `gh`, if set; `[github] gh` in the config. `nil` means search the usual places.
    public var ghPath: String?
    /// The review queue's sections, in order: the built-ins `[queue] sections` picks, then `[queue] searches`.
    public var queueSearches = PullRequestSearch.builtIns.map(\.value)

    /// The settings used when the config doesn't set them.
    public static let defaults = Settings()

    /// Creates the default settings.
    public init() {}

    /// The outcome of loading the settings from a config file.
    public struct LoadResult: Sendable {
        /// The defaults, with every valid setting from the file applied.
        public let settings: Settings
        /// Non-fatal issues, such as unknown values; the rest of the config still applies.
        public let problems: [String]
    }

    /// Reads the `[diff]`, `[github]` and `[queue]` tables from a config file.
    ///
    /// Unknown keys in those tables are reported; other tables are left to `Keymap.load(toml:)`.
    ///
    /// - Parameter toml: The contents of `config.toml`.
    /// - Returns: The settings and any non-fatal problems.
    /// - Throws: The TOML decoder's error when the file isn't valid TOML or a setting has the wrong type.
    public static func load(toml: String) throws -> LoadResult {
        let file: File
        do {
            file = try TOMLDecoder().decode(File.self, from: toml)
        } catch let error as DecodingError {
            throw KeyBindingError(description: Keymap.describe(error))
        }
        var settings = Settings()
        var problems: [String] = []

        for (key, value) in (file.diff ?? [:]).sorted(by: { $0.key < $1.key }) {
            switch key {
            case "view":
                if let view = DiffView(rawValue: value) {
                    settings.diffView = view
                } else {
                    let choices = DiffView.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ")
                    problems.append("[diff] view = \"\(value)\": expected \(choices)")
                }
            default:
                problems.append("[diff] unknown setting \"\(key)\"")
            }
        }
        for (key, value) in (file.github ?? [:]).sorted(by: { $0.key < $1.key }) {
            switch key {
            case "gh":
                let path = value.trimmingCharacters(in: .whitespaces)
                settings.ghPath = path.isEmpty ? nil : path
            default:
                problems.append("[github] unknown setting \"\(key)\"")
            }
        }
        if let queue = file.queue {
            settings.queueSearches = queueSearches(from: queue, problems: &problems)
        }
        return LoadResult(settings: settings, problems: problems)
    }

    /// Builds the queue's sections from the `[queue]` table, reporting bad entries.
    ///
    /// - Parameters:
    ///   - queue: The decoded table.
    ///   - problems: Where to add a message for each unknown key, unknown section, bad search or repeated name.
    /// - Returns: The picked built-in searches, then the custom ones, without repeated names.
    private static func queueSearches(from queue: QueueTable, problems: inout [String]) -> [PullRequestSearch] {
        problems += queue.unknownKeys.sorted().map { "[queue] unknown setting \"\($0)\"" }
        var searches: [PullRequestSearch] = []
        let builtIns = Dictionary(uniqueKeysWithValues: PullRequestSearch.builtIns.map { ($0.key, $0.value) })
        for name in queue.sections ?? PullRequestSearch.builtIns.map(\.key) {
            if let search = builtIns[name] {
                searches.append(search)
            } else {
                let choices = PullRequestSearch.builtIns.map { "\"\($0.key)\"" }.joined(separator: ", ")
                problems.append("[queue] sections: unknown section \"\(name)\"; expected \(choices)")
            }
        }
        for (index, entry) in (queue.searches ?? []).enumerated() {
            let name = entry["name"]?.trimmingCharacters(in: .whitespaces) ?? ""
            let query = entry["query"]?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !name.isEmpty, !query.isEmpty else {
                problems.append("[queue] searches[\(index)]: needs both name and query")
                continue
            }
            for key in entry.keys.sorted() where key != "name" && key != "query" {
                problems.append("[queue] searches[\(index)]: unknown setting \"\(key)\"")
            }
            searches.append(PullRequestSearch(name: name, query: query))
        }
        // Sections are identified by name, so a repeat would confuse the list.
        var names: Set<String> = []
        return searches.filter { search in
            guard names.insert(search.name).inserted else {
                problems.append("[queue] more than one section is named \"\(search.name)\"; using the first")
                return false
            }
            return true
        }
    }

    /// The tables of `config.toml` that hold settings; other tables are ignored.
    private struct File: Decodable {
        let diff: [String: String]?
        let github: [String: String]?
        let queue: QueueTable?
    }

    /// The `[queue]` table: which built-in sections to show, and custom searches.
    private struct QueueTable: Decodable {
        /// Built-in section names, in order.
        var sections: [String]?
        /// Custom searches, each with a `name` and a `query`; kept as strings so missing keys can be reported.
        var searches: [[String: String]]?
        /// Keys other than `sections` and `searches`.
        var unknownKeys: [String] = []

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keymap.AnyKey.self)
            for key in container.allKeys {
                switch key.stringValue {
                case "sections": sections = try container.decode([String].self, forKey: key)
                case "searches": searches = try container.decode([[String: String]].self, forKey: key)
                default: unknownKeys.append(key.stringValue)
                }
            }
        }
    }

    /// The commented-out settings section of the starter config, listing every setting with its default.
    static let template = """
        # How the Files tab shows a file at first: "hunks" (just the changes) or "full" (the whole file).
        # z a toggles the current file, z R expands every file, z M collapses every file.
        [diff]
        # view = "hunks"

        # Where gh is, if Maser can't find it. It looks in Homebrew, MacPorts, Nix and ~/.local/bin,
        # then asks your login shell.
        [github]
        # gh = "/opt/homebrew/bin/gh"

        # The review queue's sections. Built-ins: "review-requested", "yours" (PRs you wrote) and "involving"
        # (you commented, were mentioned or are assigned). Searches use GitHub's syntax and show open PRs
        # unless they say otherwise (is:closed, is:merged). A PR shows only in the first section that has it.
        [queue]
        # sections = ["review-requested", "yours", "involving"]
        # searches = [
        #   { name = "maser", query = "repo:bmannakee/maser" },
        #   { name = "Needs review", query = "org:my-org label:\\"needs review\\"" },
        # ]

        """
}
