// A stand-in for the GitHub CLI that replays recorded responses, for the UI scenarios.
//
// Maser runs `gh` as a subprocess, so the scenarios point `[github] gh` at this tool instead. Each recording is one
// JSON file holding a `gh` command's exact arguments and what it printed. Scenarios can also write overrides that
// answer matching commands differently, such as a failing search, a stalled one or a successful comment post, and
// every command run is logged so a scenario can check what Maser sent. With `FAKE_GH_RECORD`, read-only commands go to
// the real `gh` and are saved as new recordings; mutations are never sent to GitHub from here.
//
// Environment:
//   FAKE_GH_DIR     The recordings directory (required).
//   FAKE_GH_STATE   A directory for `overrides.json` (read) and `calls.jsonl` (appended), if set.
//   FAKE_GH_RECORD  The real `gh`'s path: record read-only commands that have no recording yet.
//   FAKE_GH_XDG_CONFIG_HOME  The real `gh`'s `XDG_CONFIG_HOME` when recording, where it finds its login; the app's
//                   own points at the scenario's config. Unset or empty means the default (`~/.config`).

import Foundation

/// One recorded `gh` command and its result.
struct Recording: Codable {
    /// The arguments, not including the executable.
    let args: [String]
    /// The exit status.
    let status: Int32
    /// Everything written to standard output.
    let stdout: String
    /// Everything written to standard error.
    let stderr: String
}

/// A scenario's answer for commands that match, checked before the recordings.
struct Override: Codable {
    /// Strings that must each appear in some argument for the override to apply.
    let match: [String]
    /// The exit status.
    let status: Int32
    /// What to write to standard output.
    let stdout: String?
    /// What to write to standard error.
    let stderr: String?
    /// Seconds to wait before answering, to stand in for a stalled network.
    let delaySeconds: Double?
}

/// One line of the call log.
struct Call: Codable {
    /// The arguments, not including the executable.
    let args: [String]
    /// The exit status returned.
    let status: Int32
    /// Where the answer came from: `override`, `recording`, `recorded` or `missing`.
    let source: String
}

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())

/// Writes a message to standard error and exits with status 2, for problems with the fake itself.
///
/// - Parameter message: What went wrong.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fake-gh: \(message)\n".utf8))
    exit(2)
}

/// The recording's file name: a readable prefix for browsing, then a hash of the exact arguments.
///
/// - Parameter args: The command's arguments.
/// - Returns: A name such as `search-prs-1a2b3c4d5e6f7a8b.json` or `api-graphql-PullRequestOverview-….json`.
func fileName(for args: [String]) -> String {
    var words = Array(args.prefix(2)).filter { !$0.hasPrefix("-") && !$0.contains("/") }
    if let query = args.first(where: { $0.hasPrefix("query=") }),
        let operation = query.firstMatch(of: #/^query=\s*(?:query|mutation)\s+(\w+)/#)
    {
        words.append(String(operation.1))
    }
    // FNV-1a: stable across runs and machines, unlike `Hasher`.
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in args.joined(separator: "\u{0}").utf8 {
        hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
    }
    return (words + [String(hash, radix: 16)]).joined(separator: "-") + ".json"
}

/// Whether a command would change something on GitHub, so it must never be recorded from the real `gh`.
///
/// - Parameter args: The command's arguments.
/// - Returns: True for GraphQL mutations, REST calls with a method other than GET, and `gh` subcommands that write.
func isMutation(_ args: [String]) -> Bool {
    if args.contains(where: {
        $0.hasPrefix("query=") && $0.dropFirst(6).trimmingCharacters(in: .whitespaces).hasPrefix("mutation")
    }) {
        return true
    }
    if let index = args.firstIndex(where: { $0 == "--method" || $0 == "-X" }), index + 1 < args.count {
        return args[index + 1].uppercased() != "GET"
    }
    if args.contains(where: { $0.hasPrefix("--method=") }) { return !args.contains("--method=GET") }
    let reads: Set<String> = ["api", "search", "pr view", "pr diff", "pr list", "auth status"]
    let command = args.prefix(2).joined(separator: " ")
    return !(reads.contains(args.first ?? "") || reads.contains(command))
}

/// Appends a call to the log, in one write so concurrent `gh` processes don't interleave lines.
///
/// - Parameter call: The call to log.
func log(_ call: Call) {
    guard let state = environment["FAKE_GH_STATE"], var line = try? JSONEncoder().encode(call) else { return }
    line.append(UInt8(ascii: "\n"))
    let descriptor = open("\(state)/calls.jsonl", O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
}

/// Prints a result and exits with its status, logging the call first.
///
/// - Parameters:
///   - status: The exit status.
///   - stdout: What to write to standard output.
///   - stderr: What to write to standard error.
///   - source: Where the answer came from, for the log.
func finish(status: Int32, stdout: String, stderr: String, source: String) -> Never {
    log(Call(args: arguments, status: status, source: source))
    FileHandle.standardOutput.write(Data(stdout.utf8))
    FileHandle.standardError.write(Data(stderr.utf8))
    exit(status)
}

guard let directory = environment["FAKE_GH_DIR"] else { fail("set FAKE_GH_DIR to the recordings directory") }

// Overrides first: they're how a scenario makes a command fail or answers a mutation.
if let state = environment["FAKE_GH_STATE"],
    let data = FileManager.default.contents(atPath: "\(state)/overrides.json")
{
    guard let overrides = try? JSONDecoder().decode([Override].self, from: data) else { fail("can't read overrides.json") }
    let matched = overrides.first { override in
        override.match.allSatisfy { needle in arguments.contains { $0.contains(needle) } }
    }
    if let matched {
        if let delay = matched.delaySeconds { Thread.sleep(forTimeInterval: delay) }
        finish(status: matched.status, stdout: matched.stdout ?? "", stderr: matched.stderr ?? "", source: "override")
    }
}

let url = URL(filePath: directory).appending(path: fileName(for: arguments))
if let data = FileManager.default.contents(atPath: url.path()) {
    guard let recording = try? JSONDecoder().decode(Recording.self, from: data) else { fail("can't read \(url.path())") }
    guard recording.args == arguments else { fail("\(url.lastPathComponent) records different arguments (hash clash)") }
    finish(status: recording.status, stdout: recording.stdout, stderr: recording.stderr, source: "recording")
}

guard let real = environment["FAKE_GH_RECORD"], !real.isEmpty else {
    let command = arguments.map { $0.count > 80 ? "\($0.prefix(77))…" : $0 }.joined(separator: " ")
    finish(status: 1, stdout: "", stderr: "fake-gh: no recording for: gh \(command)\n", source: "missing")
}
guard !isMutation(arguments) else {
    finish(status: 1, stdout: "", stderr: "fake-gh: won't send a mutation to GitHub while recording\n", source: "missing")
}

// Record: run the real gh and keep what it printed, failures included.
let process = Process()
process.executableURL = URL(filePath: real)
process.arguments = arguments
var realEnvironment = environment
realEnvironment["XDG_CONFIG_HOME"] = environment["FAKE_GH_XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
process.environment = realEnvironment
let stdoutPipe = Pipe()
let stderrPipe = Pipe()
process.standardOutput = stdoutPipe
process.standardError = stderrPipe
do { try process.run() } catch { fail("can't run \(real): \(error)") }
// Read before waiting, so a large response can't fill the pipe and stall gh.
let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()
// Status 4 is gh's "not logged in": a problem with the recording setup, not an answer worth replaying.
guard process.terminationStatus != 4 else {
    finish(
        status: 4, stdout: "", stderr: String(decoding: stderr, as: UTF8.self) + "fake-gh: not recorded\n",
        source: "missing")
}
let recording = Recording(
    args: arguments, status: process.terminationStatus, stdout: String(decoding: stdout, as: UTF8.self),
    stderr: String(decoding: stderr, as: UTF8.self))
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
do { try encoder.encode(recording).write(to: url) } catch { fail("can't write \(url.path()): \(error)") }
finish(status: recording.status, stdout: recording.stdout, stderr: recording.stderr, source: "recorded")
