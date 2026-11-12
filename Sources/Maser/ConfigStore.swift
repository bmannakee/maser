// The user's config file and the key bindings and settings loaded from it.
//
// `ConfigStore` finds `config.toml`, parses it into a `Keymap` and `Settings`, and reloads it whenever the file changes,
// so edits take effect without restarting. Problems in the file are collected for the banner that `configProblemsBanner()` shows.
// `FileWatcher` does the change detection.

import AppKit
import MaserCore
import Observation
import os

/// Logs config loads and errors.
let configLog = Logger(subsystem: "dev.maser", category: "config")

/// The user's `config.toml`, reloaded whenever it changes.
///
/// The file lives at `$XDG_CONFIG_HOME/maser/config.toml`, or `~/.config/maser/config.toml` when that isn't set. A
/// missing file means the default bindings.
@MainActor @Observable
final class ConfigStore {
    /// The app's single store, started at launch.
    static let shared = ConfigStore()

    /// The current bindings: the defaults, or the last config that parsed.
    private(set) var keymap = Keymap.defaults
    /// The current settings: the defaults, or the last config that parsed.
    private(set) var settings = Settings.defaults {
        didSet { GitHubCLI.setConfiguredExecutable(settings.ghPath) }
    }
    /// Human-readable problems from the last load, such as unknown commands or a read or parse error.
    private(set) var problems: [String] = []

    #if DEBUG
        /// Changes the agent's settings in memory, for UI scenarios that need the agent off or configured differently.
        ///
        /// - Parameter change: Changes the settings in place.
        func overrideAgentSettings(_ change: (inout AgentSettings) -> Void) {
            change(&settings.agent)
        }
    #endif
    /// Whether the user closed the problems banner; reset whenever the list of problems changes.
    var problemsDismissed = false

    /// Where the config file is, whether or not it exists.
    let fileURL: URL
    @ObservationIgnored private var watcher: FileWatcher?

    /// Resolves the config path from `XDG_CONFIG_HOME`, treating an empty value as unset.
    private init() {
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let base =
            xdg.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config", directoryHint: .isDirectory)
        fileURL = base.appending(path: "maser/config.toml")
    }

    /// The config path for display, with the home directory shown as `~`.
    var displayPath: String { (fileURL.path as NSString).abbreviatingWithTildeInPath }

    /// Loads the config and starts reloading it whenever it changes.
    func start() {
        reload()
        watcher = FileWatcher(paths: { [fileURL] in Self.watchPaths(for: fileURL) }) { [weak self] in
            self?.reload()
        }
        watcher?.start()
    }

    /// Reads and parses the config file, updating `keymap` and `problems`.
    ///
    /// A missing file restores the defaults. If the file can't be read or doesn't parse, the previous bindings stay in
    /// effect and the error is reported in `problems`.
    func reload() {
        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            keymap = .defaults
            settings = .defaults
            setProblems([])
            configLog.notice("No config at \(self.displayPath, privacy: .public); using defaults")
            return
        } catch {
            setProblems(["Couldn't read \(displayPath): \(error.localizedDescription)"])
            return
        }

        do {
            let result = try Keymap.load(toml: text)
            let settingsResult = try Settings.load(toml: text)
            keymap = result.keymap
            settings = settingsResult.settings
            let problems = result.problems + settingsResult.problems
            setProblems(problems)
            configLog.notice(
                "Loaded \(self.displayPath, privacy: .public) with \(problems.count) problem(s): \(problems.joined(separator: " | "), privacy: .public)"
            )
        } catch {
            // Keep the last good bindings while the file is mid-edit.
            let message = (error as? KeyBindingError)?.description ?? error.localizedDescription
            setProblems(["\(message) — keeping the previous bindings until this is fixed"])
            configLog.notice("Config error, keeping previous bindings: \(message, privacy: .public)")
        }
    }

    /// Opens the config in its default editor, creating it from the template first if needed.
    ///
    /// Falls back to TextEdit when no app is registered for `.toml` files. If the file can't be created, the error is
    /// reported in `problems` instead.
    func openConfigFile() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: fileURL.path) {
            do {
                try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Keymap.template.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                setProblems(["Couldn't create \(displayPath): \(error.localizedDescription)"])
                return
            }
            watcher?.start()  // Re-arm so the newly created directory and file are watched too.
        }
        if NSWorkspace.shared.urlForApplication(toOpen: fileURL) != nil {
            NSWorkspace.shared.open(fileURL)
        } else {
            // No app claims .toml; fall back to TextEdit.
            NSWorkspace.shared.open(
                [fileURL],
                withApplicationAt: URL(filePath: "/System/Applications/TextEdit.app"),
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }

    /// Lists every way to trigger a command, such as `"⌥⌘↓ or j"`.
    ///
    /// - Parameter command: The command to describe.
    /// - Returns: The menu shortcut first, then each vim-style sequence, joined with "or"; `nil` if the command is unbound.
    func bindingSummary(for command: CommandID) -> String? {
        let all =
            [keymap.menu[command]?.symbols].compactMap(\.self)
            + (keymap.normal[command] ?? []).map(Keymap.format)
        return all.isEmpty ? nil : all.joined(separator: " or ")
    }

    /// Replaces `problems`, showing the banner again only if the list actually changed.
    private func setProblems(_ new: [String]) {
        guard new != problems else { return }
        problems = new
        problemsDismissed = false
    }

    /// The existing paths to watch so that any change to the config is noticed.
    ///
    /// Editors often save by replacing the file, and dotfiles setups symlink it elsewhere, so this covers the file, its
    /// directory and that directory's parent (to see `maser/` being created), plus the symlink target and its directory.
    ///
    /// - Parameter fileURL: The config file's location.
    /// - Returns: Distinct paths that exist right now.
    private static func watchPaths(for fileURL: URL) -> [String] {
        let directory = fileURL.deletingLastPathComponent()
        let resolved = fileURL.resolvingSymlinksInPath()
        let candidates = [
            directory.deletingLastPathComponent(), directory, fileURL,
            resolved, resolved.deletingLastPathComponent(),
        ].map(\.path)
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0) }
    }
}

/// Calls `onChange`, debounced, when any watched path changes.
///
/// After each change it asks for the paths again and re-arms, so files that were replaced or newly created are watched.
@MainActor
final class FileWatcher {
    /// Produces the paths to watch; asked again each time the watcher re-arms.
    private let paths: () -> [String]
    private let onChange: @MainActor () -> Void
    /// One dispatch source per open path; cancelling a source closes its file descriptor.
    private var sources: [any DispatchSourceFileSystemObject] = []
    /// The pending `onChange` call, replaced by each new event so a burst of events triggers one call.
    private var debounce: Task<Void, Never>?

    /// Creates a stopped watcher; call `start()` to begin watching.
    ///
    /// - Parameters:
    ///   - paths: Returns the paths to watch. Paths that can't be opened are skipped.
    ///   - onChange: Called on the main actor 150 ms after the last change in a burst.
    init(paths: @escaping () -> [String], onChange: @escaping @MainActor () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    /// Starts watching the current paths, replacing any earlier watch.
    func start() {
        stop()
        for path in paths() {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.changed() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    /// Stops watching and closes every watched file.
    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
    }

    /// Schedules `onChange` after a short pause, restarting the wait if another event comes first.
    private func changed() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            onChange()
            start()  // Files may have been replaced; watch the new ones.
        }
    }
}
