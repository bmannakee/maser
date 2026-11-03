// The non-key settings in `config.toml`.
//
// Alongside the key bindings (see `Keymap`), the config file has a few plain settings: how the Files tab shows a file
// at first, and where `gh` is when the app can't find it. `Settings.load(toml:)` reads them, falling back to defaults
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

    /// Reads the `[diff]` and `[github]` tables from a config file.
    ///
    /// Unknown keys in those tables are reported; other tables are left to `Keymap.load(toml:)`.
    ///
    /// - Parameter toml: The contents of `config.toml`.
    /// - Returns: The settings and any non-fatal problems.
    /// - Throws: The TOML decoder's error when the file isn't valid TOML or a setting isn't a string.
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
        return LoadResult(settings: settings, problems: problems)
    }

    /// The tables of `config.toml` that hold settings; other tables are ignored.
    private struct File: Decodable {
        let diff: [String: String]?
        let github: [String: String]?
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

        """
}
