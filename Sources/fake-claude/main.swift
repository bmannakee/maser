// A stand-in for `claude`, for the UI scenarios: it answers in claude's stream-json shapes without a model.
//
// Run with the review agent's command line, it starts the MCP server named in `--mcp-config` (Maser's real helper)
// and talks to it, so tool calls go through the real bridge into Maser. For each message it prints an `init` event,
// then, depending on the message:
//
// - containing "pr_context": calls that tool and answers with the first line it returned;
// - containing "outside": tries to read /etc/hosts and reports it refused, as `dontAsk` mode would;
// - anything else: answers "You said: …".
//
// It ends each turn with a `result` whose cost grows by $0.01 per turn across a session, even after `--resume`, as
// claude's does. `FAKE_CLAUDE_LOG` names a JSON-lines file where it logs its arguments, working directory and messages.

import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
/// The value after a flag.
func value(_ flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
}

let logPath = ProcessInfo.processInfo.environment["FAKE_CLAUDE_LOG"]
/// Appends one entry to the log, if there is one.
func log(_ entry: [String: Any]) {
    guard let logPath, let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
    if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
    guard let handle = FileHandle(forWritingAtPath: logPath) else { return }
    handle.seekToEndOfFile()
    handle.write(data + Data("\n".utf8))
    try? handle.close()
}

/// Prints one event as a line.
func emit(_ event: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

log(["args": arguments, "cwd": FileManager.default.currentDirectoryPath])

let sessionID = value("--resume") ?? UUID().uuidString.lowercased()
let model = value("--model") ?? "claude-opus-5-5"
// The session's running cost, kept beside the log so a resumed session carries on from it.
let costPath = logPath.map {
    URL(filePath: $0).deletingLastPathComponent().appending(path: "\(sessionID).cost").path(percentEncoded: false)
}
var totalCost = costPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }.flatMap(Double.init) ?? 0

// MARK: - The MCP server from --mcp-config

/// Maser's helper, started as claude would start it.
final class MCPServer {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    var nextID = 1
    var tools: [String] = []

    init?(configPath: String) {
        guard let data = FileManager.default.contents(atPath: configPath),
            let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let servers = config["mcpServers"] as? [String: Any], let maser = servers["maser"] as? [String: Any],
            let command = maser["command"] as? String
        else { return nil }
        process.executableURL = URL(filePath: command)
        process.arguments = maser["args"] as? [String] ?? []
        process.environment = ProcessInfo.processInfo.environment.merging(maser["env"] as? [String: String] ?? [:]) { _, new in
            new
        }
        process.standardInput = input
        process.standardOutput = output
        guard (try? process.run()) != nil else { return nil }
        _ = request(
            "initialize",
            ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "fake-claude"]])
        let list = request("tools/list", [:])
        tools = ((list?["tools"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }

    /// Sends a request and waits for its answer.
    func request(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        let message: [String: Any] = ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params]
        nextID += 1
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        input.fileHandleForWriting.write(data + Data("\n".utf8))
        var line = Data()
        while true {
            let byte = output.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data("\n".utf8) { break }
            line.append(byte)
        }
        return ((try? JSONSerialization.jsonObject(with: line)) as? [String: Any])?["result"] as? [String: Any]
    }
}

let server = value("--mcp-config").flatMap { MCPServer(configPath: $0) }
var callNumber = 0

// MARK: - Turns

while let line = readLine() {
    guard let data = line.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let message = object["message"] as? [String: Any], let text = message["content"] as? String
    else { continue }
    log(["message": text])
    emit([
        "type": "system", "subtype": "init", "session_id": sessionID, "model": model,
        "permissionMode": value("--permission-mode") ?? "default",
        "tools": ["Glob", "Grep", "Read"] + (server?.tools ?? []).map { "mcp__maser__\($0)" },
        "mcp_servers": server == nil ? [] : [["name": "maser", "status": "connected", "source": "dynamic"]],
    ])
    var answer = "You said: \(text)"
    var denials: [[String: Any]] = []
    callNumber += 1
    let callID = "toolu_fake_\(callNumber)"
    if text.contains("pr_context"), let server {
        emit([
            "type": "assistant", "session_id": sessionID,
            "message": [
                "role": "assistant",
                "content": [["type": "tool_use", "id": callID, "name": "mcp__maser__pr_context", "input": [String: Any]()]],
            ],
        ])
        let result = server.request("tools/call", ["name": "pr_context", "arguments": [String: Any]()])
        let content = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let isError = result?["isError"] as? Bool ?? true
        emit([
            "type": "user", "session_id": sessionID,
            "message": [
                "role": "user",
                "content": [["type": "tool_result", "tool_use_id": callID, "content": content, "is_error": isError]],
            ],
        ])
        answer = "Read the PR: \(content.split(separator: "\n").first ?? "")"
    } else if text.contains("outside") {
        let refusal = "Permission to use Read has been denied because Claude Code is running in don't ask mode."
        emit([
            "type": "assistant", "session_id": sessionID,
            "message": [
                "role": "assistant",
                "content": [["type": "tool_use", "id": callID, "name": "Read", "input": ["file_path": "/etc/hosts"]]],
            ],
        ])
        emit([
            "type": "system", "subtype": "permission_denied", "tool_name": "Read", "tool_use_id": callID, "message": refusal,
            "session_id": sessionID,
        ])
        emit([
            "type": "user", "session_id": sessionID,
            "message": [
                "role": "user",
                "content": [["type": "tool_result", "tool_use_id": callID, "content": refusal, "is_error": true]],
            ],
        ])
        denials.append(["tool_name": "Read", "tool_use_id": callID, "tool_input": ["file_path": "/etc/hosts"]])
        answer = "I couldn't read /etc/hosts: it's outside my checkout."
    }
    emit([
        "type": "assistant", "session_id": sessionID,
        "message": ["role": "assistant", "content": [["type": "text", "text": answer]]],
    ])
    totalCost += 0.01
    if let costPath { try? String(totalCost).write(toFile: costPath, atomically: true, encoding: .utf8) }
    emit([
        "type": "result", "subtype": "success", "is_error": false, "result": answer, "session_id": sessionID,
        "total_cost_usd": totalCost, "permission_denials": denials, "stop_reason": "end_turn", "num_turns": 1,
    ])
}
