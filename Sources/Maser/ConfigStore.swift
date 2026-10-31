import AppKit
import MaserCore
import Observation
import os

let configLog = Logger(subsystem: "dev.maser", category: "config")

/// The user's `config.toml` (`$XDG_CONFIG_HOME/maser/config.toml`, default `~/.config/maser/config.toml`),
/// reloaded whenever it changes.
@MainActor @Observable
final class ConfigStore {
    static let shared = ConfigStore()

    private(set) var keymap = Keymap.defaults
    private(set) var problems: [String] = []
    var problemsDismissed = false

    let fileURL: URL
    @ObservationIgnored private var watcher: FileWatcher?

    private init() {
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
        let base = xdg.map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config", directoryHint: .isDirectory)
        fileURL = base.appending(path: "maser/config.toml")
    }

    var displayPath: String { (fileURL.path as NSString).abbreviatingWithTildeInPath }

    func start() {
        reload()
        watcher = FileWatcher(paths: { [fileURL] in Self.watchPaths(for: fileURL) }) { [weak self] in
            self?.reload()
        }
        watcher?.start()
    }

    func reload() {
        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            keymap = .defaults
            setProblems([])
            configLog.notice("No config at \(self.displayPath, privacy: .public); using defaults")
            return
        } catch {
            setProblems(["Couldn't read \(displayPath): \(error.localizedDescription)"])
            return
        }

        do {
            let result = try Keymap.load(toml: text)
            keymap = result.keymap
            setProblems(result.problems)
            configLog.notice("Loaded \(self.displayPath, privacy: .public) with \(result.problems.count) problem(s): \(result.problems.joined(separator: " | "), privacy: .public)")
        } catch {
            // Keep the last good bindings while the file is mid-edit.
            let message = (error as? KeyBindingError)?.description ?? error.localizedDescription
            setProblems(["\(message) — keeping the previous bindings until this is fixed"])
            configLog.notice("Config error, keeping previous bindings: \(message, privacy: .public)")
        }
    }

    /// Opens the config in its default editor, creating it from the template first if needed.
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
            watcher?.start() // pick up the newly created directory/file
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

    /// e.g. "⌥⌘↓ or j" — every way to trigger a command.
    func bindingSummary(for command: CommandID) -> String? {
        let all = [keymap.menu[command]?.symbols].compactMap(\.self)
            + (keymap.normal[command] ?? []).map(Keymap.format)
        return all.isEmpty ? nil : all.joined(separator: " or ")
    }

    private func setProblems(_ new: [String]) {
        guard new != problems else { return }
        problems = new
        problemsDismissed = false
    }

    /// Editors often save by replacing the file, and dotfiles setups symlink it elsewhere, so watch
    /// the file, its directory, and (for symlinks) the real file and its directory.
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

/// Calls `onChange` (debounced) when any watched path changes; re-arms itself each time.
@MainActor
final class FileWatcher {
    private let paths: () -> [String]
    private let onChange: @MainActor () -> Void
    private var sources: [any DispatchSourceFileSystemObject] = []
    private var debounce: Task<Void, Never>?

    init(paths: @escaping () -> [String], onChange: @escaping @MainActor () -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

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

    func stop() {
        sources.forEach { $0.cancel() }
        sources = []
    }

    private func changed() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            onChange()
            start() // files may have been replaced; watch the new ones
        }
    }
}
