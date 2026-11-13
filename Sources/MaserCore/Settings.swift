// The non-key settings in `config.toml`.
//
// Alongside the key bindings (see `Keymap`), the config file has a few plain settings: how the Files tab shows a file
// at first, where `gh` is when the app can't find it, the review queue's sections, and the review agent's settings.
// `Settings.load(toml:)` reads them, falling back to defaults and reporting problems the same way the keymap does.

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
    /// How many seconds a `gh` call may run before Maser stops it; `[github] timeout` in the config.
    ///
    /// A diff or a file's contents get twice as long.
    public var ghTimeoutSeconds = 60
    /// The review queue's sections, in order: the built-ins `[queue] sections` picks, then `[queue] searches`.
    public var queueSearches = PullRequestSearch.builtIns.map(\.value)
    /// The review agent's settings; the `[agent]` table.
    public var agent = AgentSettings()

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

    /// Reads the `[diff]`, `[github]`, `[queue]` and `[agent]` tables from a config file.
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
        if let github = file.github {
            settings.ghPath = github.ghPath
            settings.ghTimeoutSeconds = github.timeoutSeconds ?? settings.ghTimeoutSeconds
            problems += github.problems
        }
        if let queue = file.queue {
            settings.queueSearches = queueSearches(from: queue, problems: &problems)
        }
        if let agent = file.agent {
            settings.agent = agent.settings
            problems += agent.problems
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
        let github: GitHubTable?
        let queue: QueueTable?
        let agent: AgentTable?
    }

    /// The `[github]` table, read key by key so a wrong value is reported rather than failing the whole file.
    private struct GitHubTable: Decodable {
        /// The `gh` path, if set and not blank.
        var ghPath: String?
        /// The timeout, if set to a valid value.
        var timeoutSeconds: Int?
        /// A message for each unknown key or bad value.
        var problems: [String] = []

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keymap.AnyKey.self)
            for key in container.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                let name = "[github] \(key.stringValue)"
                switch key.stringValue {
                case "gh":
                    if let path = try? container.decode(String.self, forKey: key) {
                        let trimmed = path.trimmingCharacters(in: .whitespaces)
                        ghPath = trimmed.isEmpty ? nil : trimmed
                    } else {
                        problems.append("\(name): expected a path in quotes")
                    }
                case "timeout":
                    if let seconds = try? container.decode(Int.self, forKey: key), seconds > 0 {
                        timeoutSeconds = seconds
                    } else {
                        problems.append("\(name): expected a number of seconds above 0, such as 60")
                    }
                default:
                    problems.append("[github] unknown setting \"\(key.stringValue)\"")
                }
            }
        }
    }

    /// The `[agent]` table, read key by key so a wrong value is reported rather than failing the whole file.
    private struct AgentTable: Decodable {
        /// The settings read, starting from the defaults.
        var settings = AgentSettings()
        /// A message for each unknown key or bad value.
        var problems: [String] = []

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keymap.AnyKey.self)
            for key in container.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
                let name = "[agent] \(key.stringValue)"
                switch key.stringValue {
                case "claude":
                    if let path = try? container.decode(String.self, forKey: key) {
                        let trimmed = path.trimmingCharacters(in: .whitespaces)
                        settings.claudePath = trimmed.isEmpty ? nil : trimmed
                    } else {
                        problems.append("\(name): expected a path in quotes")
                    }
                case "allow":
                    if let entries = try? container.decode([String].self, forKey: key) {
                        for entry in entries {
                            if let rule = AgentSettings.AllowRule(entry) {
                                settings.allow.append(rule)
                            } else {
                                problems.append(
                                    "\(name): \"\(entry)\" isn't an owner (\"my-org\"), a host (\"github.example.com\") or a host and owner (\"github.example.com/my-org\")"
                                )
                            }
                        }
                    } else {
                        problems.append("\(name): expected a list of owners or hosts, such as [\"my-org\"]")
                    }
                case "model":
                    if let model = try? container.decode(String.self, forKey: key) {
                        let trimmed = model.trimmingCharacters(in: .whitespaces)
                        settings.model = trimmed.isEmpty ? nil : trimmed
                    } else {
                        problems.append("\(name): expected a model name in quotes, such as \"claude-opus-5-5\"")
                    }
                case "effort":
                    let value = try? container.decode(String.self, forKey: key)
                    if let effort = value.flatMap(AgentSettings.Effort.init(rawValue:)) {
                        settings.effort = effort
                    } else {
                        let choices = AgentSettings.Effort.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                        problems.append("\(name): expected one of \(choices)")
                    }
                case "max_budget_usd":
                    // TOML writes 2 and 2.0 differently; accept either.
                    let amount =
                        (try? container.decode(Double.self, forKey: key))
                        ?? (try? container.decode(Int.self, forKey: key)).map(Double.init)
                    if let amount, amount > 0 {
                        settings.maxBudgetUSD = amount
                    } else {
                        problems.append("\(name): expected an amount in dollars above 0, such as 2.5")
                    }
                case "repositories":
                    if let folders = try? container.decode([String].self, forKey: key) {
                        settings.repositories = folders.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    } else {
                        problems.append("\(name): expected a list of folders, such as [\"~/dev\"]")
                    }
                default:
                    problems.append("[agent] unknown setting \"\(key.stringValue)\"")
                }
            }
        }
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
        # How many seconds to wait for gh before giving up, so a stalled network shows a message rather than
        # loading forever. Loading a diff gets twice as long.
        # timeout = 60

        # The review queue's sections. Built-ins: "review-requested", "yours" (PRs you wrote) and "involving"
        # (you commented, were mentioned or are assigned). Searches use GitHub's syntax and show open PRs
        # unless they say otherwise (is:closed, is:merged). A PR shows only in the first section that has it.
        [queue]
        # sections = ["review-requested", "yours", "involving"]
        # searches = [
        #   { name = "maser", query = "repo:bmannakee/maser" },
        #   { name = "Needs review", query = "org:my-org label:\\"needs review\\"" },
        # ]

        # The review agent (planned), which runs your own claude command-line tool. It's off for every PR until
        # allow names the PR's owner, a host, or a host and owner. Allow only code its owner lets you send to the
        # model provider.
        [agent]
        # allow = ["my-name", "github.example.com/my-org"]
        # claude = "/opt/homebrew/bin/claude"
        # model = "claude-opus-5-5"
        # effort = "high"
        # max_budget_usd = 2.0
        # repositories = ["~/dev"]

        """
}
