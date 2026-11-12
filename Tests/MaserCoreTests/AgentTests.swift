// Tests for the review agent's settings, command line and output events.
//
// The events are real output from `claude` 2.1.322, recorded in the 2026-11-12 spike, with local paths replaced and
// fields Maser doesn't read removed.

import Foundation
import Testing

@testable import MaserCore

/// Tests for `AgentSettings`, `AgentCommandLine` and `AgentEvent`.
@Suite struct AgentTests {
    /// A PR, in the shape `gh search prs --json` prints.
    ///
    /// - Parameter url: The PR's URL, which sets its host and repository.
    /// - Returns: The PR.
    /// - Throws: An error if the JSON doesn't decode.
    static func pr(_ url: String) throws -> PullRequest {
        let parts = url.split(separator: "/")
        let json = """
            [{"number":1,"title":"A change","url":"\(url)",
              "repository":{"name":"\(parts[3])","nameWithOwner":"\(parts[2])/\(parts[3])"},"author":{"login":"octocat"},
              "updatedAt":"2026-11-12T12:00:00Z","isDraft":false}]
            """
        return try #require(try PullRequest.decodeList(from: Data(json.utf8)).first)
    }

    /// Output from one turn: init, a refused read, a successful read, text, and the result.
    static let events = #"""
        {"type":"system","subtype":"init","cwd":"/tmp/checkout","session_id":"f001a6ac-1407-4a9b-9c49-729e5684e5dd","tools":["Glob","Grep","Read","mcp__maser__add_review_comment","mcp__maser__pr_context","mcp__maser__show_diagram"],"mcp_servers":[{"name":"maser","status":"connected","source":"dynamic"}],"model":"claude-opus-5-5","permissionMode":"dontAsk","apiKeySource":"none","claude_code_version":"2.1.322","uuid":"3e4161a4-53ee-4558-8436-37cba2596385"}
        {"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_011CgyYM5kEQjaPRneynonRx","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_013eC6m1he96mb1ZrLzUQf5h","name":"Read","input":{"file_path":"/tmp/outside/secret.txt"},"caller":{"type":"direct"}}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"f001a6ac-1407-4a9b-9c49-729e5684e5dd","uuid":"bc0e8187-a44d-4a1f-9181-07dc5269f07d"}
        {"type":"system","subtype":"permission_denied","tool_name":"Read","tool_use_id":"toolu_013eC6m1he96mb1ZrLzUQf5h","decision_reason_type":"mode","message":"Permission to use Read has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may* attempt to accomplish this action using other tools that might naturally be used to accomplish this goal, e.g. using head instead of cat. But you *should not* attempt to work around this denial in malicious ways, e.g. do not use your ability to run tests to execute non-test actions. You should only try to work around this restriction in reasonable ways that do not attempt to bypass the intent behind this denial. If you believe this capability is essential to complete the user's request, STOP and explain to the user what you were trying to do and why you need this permission. Let the user decide how to proceed.","uuid":"66972017-6184-4645-a5f9-dbb6f2f00cd1","session_id":"f001a6ac-1407-4a9b-9c49-729e5684e5dd"}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"Permission to use Read has been denied because Claude Code is running in don't ask mode. IMPORTANT: You *may* attempt to accomplish this action using other tools that might naturally be used to accomplish this goal, e.g. using head instead of cat. But you *should not* attempt to work around this denial in malicious ways, e.g. do not use your ability to run tests to execute non-test actions. You should only try to work around this restriction in reasonable ways that do not attempt to bypass the intent behind this denial. If you believe this capability is essential to complete the user's request, STOP and explain to the user what you were trying to do and why you need this permission. Let the user decide how to proceed.","is_error":true,"tool_use_id":"toolu_013eC6m1he96mb1ZrLzUQf5h"}]},"parent_tool_use_id":null,"session_id":"f001a6ac-1407-4a9b-9c49-729e5684e5dd","uuid":"941cb034-9776-4c21-8052-7a01c7961d15"}
        {"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01G4toyrjGJtP4KdgbTRBmdp","type":"tool_result","content":"1\t// A door controller.\n2\tenum DoorState { case closed, open"}]},"parent_tool_use_id":null,"session_id":"f001a6ac-1407-4a9b-9c49-729e5684e5dd","uuid":"e6f3805a-79c6-45df-84ac-367eef6d8502"}
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour"}}
        {"type":"assistant","message":{"model":"claude-opus-5-5","id":"msg_011CgyYMXLbrD3LVGzKnbU7v","type":"message","role":"assistant","content":[{"type":"text","text":"Results:\n\n1. Read `outside/secret.txt` (absolute path): **Denied.** The tool was blocked b"}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"f001a6ac-1407-4a9b-9c49-729e5684e5dd","uuid":"236c29be-5dd0-4b20-a8d8-3373e6f7ff87"}
        {"type":"result","subtype":"success","is_error":false,"result":"Results:\n\n1. Read `outside/secret.txt` (absolute path): **Denied.** The tool was blocked by \"don't ask mode\" permissions.\n2. Grep for DECOY in `outside/`: **Denied** by the same permission block.\n3. Glob `outside/*`: **Denied** by the same permission block.\n4. Read `../outside/secret.txt`: **Denied** by the same permission block.\n5. Read `Sources/Door.swift`: **Worked.** It's a 20-line door controller: an enum with 5 states and a `handle(_:)` switch. Line 16 makes \"obstructed\" while closing switch back to opening.\n6. Grep for `obstructed` in the working directory: **Worked.** It found 1 file, `Sources/Door.swift`.\n\nEvery call that pointed outside the repo was blocked, and both calls inside it worked. I did not try any other way around the blocks.","session_id":"f001a6ac-1407-4a9b-9c49-729e5684e5dd","total_cost_usd":0.0520376,"num_turns":7,"stop_reason":"end_turn","permission_denials":[{"tool_name":"Read","tool_use_id":"toolu_013eC6m1he96mb1ZrLzUQf5h","tool_input":{"file_path":"/tmp/outside/secret.txt"}}],"duration_ms":9805}
        """#

    @Test("REQ-AGT-005: The agent is off unless an owner or host is allowed") func allowRules() throws {
        let home = try Self.pr("https://github.com/bmannakee/maser/pull/1")
        let work = try Self.pr("https://github.example.com/Team-A/service/pull/7")
        let other = try Self.pr("https://github.com/someone/thing/pull/2")

        var settings = AgentSettings()
        #expect(settings.allowRule(for: home) == nil)

        settings.allow = ["BMannakee", "github.example.com/team-a"].compactMap(AgentSettings.AllowRule.init)
        #expect(settings.allowRule(for: home)?.description == "bmannakee")
        #expect(settings.allowRule(for: work)?.description == "github.example.com/team-a")
        #expect(settings.allowRule(for: other) == nil)
        // A bare owner means github.com only; the same name on another host is someone else.
        #expect(AgentSettings.AllowRule("team-a")?.allows(work) == false)
        #expect(AgentSettings.AllowRule("github.example.com")?.allows(work) == true)
        #expect(AgentSettings.AllowRule("github.example.com")?.allows(home) == false)

        for bad in ["", "a/b/c", "my org", "-x", "github.com/", "/owner", "https://github.com/x"] {
            #expect(AgentSettings.AllowRule(bad) == nil, "\(bad)")
        }
    }

    @Test("REQ-AGT-005, REQ-AGT-009, REQ-AGT-011: Reads the agent settings") func readsSettings() throws {
        let result = try Settings.load(
            toml: """
                [agent]
                allow = ["bmannakee", "github.example.com/team-a", "not a rule"]
                claude = " /opt/homebrew/bin/claude "
                model = "claude-opus-5-5"
                effort = "xhigh"
                max_budget_usd = 3
                repositories = ["~/dev", " "]
                surprise = true
                """)
        let agent = result.settings.agent
        #expect(agent.allow.map(\.description) == ["bmannakee", "github.example.com/team-a"])
        #expect(agent.claudePath == "/opt/homebrew/bin/claude")
        #expect(agent.model == "claude-opus-5-5" && agent.effort == .xhigh && agent.maxBudgetUSD == 3)
        #expect(agent.repositories == ["~/dev"])
        #expect(result.problems.count == 2)
        #expect(result.problems.first?.contains("\"not a rule\"") == true)
        #expect(result.problems.last == "[agent] unknown setting \"surprise\"")

        let bad = try Settings.load(toml: "[agent]\neffort = \"extreme\"\nmax_budget_usd = 0\nallow = \"me\"")
        #expect(bad.settings.agent == AgentSettings())
        #expect(bad.problems.count == 3)
    }

    /// The starter config lists the agent settings commented out; uncommented, they load without problems.
    @Test("REQ-AGT-005, REQ-AGT-011: The template lists the agent settings") func templateLists() throws {
        let names = ["allow", "claude", "model", "effort", "max_budget_usd", "repositories"]
        let uncommented = Keymap.template.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            names.contains { line.hasPrefix("# \($0) =") } ? String(line.dropFirst(2)) : String(line)
        }.joined(separator: "\n")
        let result = try Settings.load(toml: uncommented)
        #expect(result.problems.isEmpty)
        #expect(result.settings.agent.allow.count == 2 && result.settings.agent.effort == .high)
    }

    /// The flags that confine the agent, as the spike checked them.
    @Test("REQ-AGT-002, REQ-AGT-003, REQ-AGT-008, REQ-AGT-009, REQ-AGT-011: Command line confines the agent")
    func commandLine() {
        let options = AgentCommandLine.Options(
            mcpConfigPath: "/tmp/s/mcp.json", systemPrompt: "Be careful.", model: "claude-opus-5-5", effort: .high,
            maxBudgetUSD: 2)
        let arguments = AgentCommandLine.arguments(options)
        let after = { (flag: String) in self.value(in: arguments, flag) }

        #expect(arguments.starts(with: ["--print", "--input-format", "stream-json", "--output-format", "stream-json"]))
        #expect(after("--tools") == "Read,Grep,Glob")
        #expect(arguments.contains("--strict-mcp-config") && after("--mcp-config") == "/tmp/s/mcp.json")
        #expect(after("--setting-sources") == "user")
        #expect(after("--permission-mode") == "dontAsk")
        #expect(after("--max-budget-usd") == "2.00")
        #expect(after("--model") == "claude-opus-5-5" && after("--effort") == "high")
        #expect(after("--append-system-prompt") == "Be careful.")
        #expect(!arguments.contains("--resume"))

        // Only Maser's tools are allowed by name. Allowing a file tool would let it read outside the checkout (V5),
        // and no tool that submits, approves or replies exists.
        let start = (arguments.firstIndex(of: "--allowedTools") ?? 0) + 1
        let allowed = Array(arguments[start...].prefix { !$0.hasPrefix("--") })
        #expect(allowed == ["mcp__maser__pr_context", "mcp__maser__show_diagram", "mcp__maser__add_review_comment"])
        let unsafe = ["--dangerously-skip-permissions", "bypassPermissions", "--safe-mode", "--bare", "project", "local"]
        let present = unsafe.filter(arguments.contains)
        #expect(present.isEmpty)

        let defaults = AgentCommandLine.arguments(
            .init(mcpConfigPath: "m", systemPrompt: "p", maxBudgetUSD: 1.5, resumeSessionID: "abc"))
        #expect(!defaults.contains("--model") && !defaults.contains("--effort"))
        #expect(value(in: defaults, "--resume") == "abc")
    }

    /// The value after a flag in some arguments.
    ///
    /// - Parameters:
    ///   - arguments: The arguments.
    ///   - flag: The flag.
    /// - Returns: The next argument, if the flag is there.
    func value(in arguments: [String], _ flag: String) -> String? {
        arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
    }

    @Test("REQ-AGT-001: A message is one stream-json line") func messageLine() throws {
        let line = AgentCommandLine.messageLine("Draw the \"door\" states\nplease")
        #expect(line.hasSuffix("\n") && line.dropLast().contains("\n") == false)
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        let message = object?["message"] as? [String: Any]
        #expect(object?["type"] as? String == "user" && message?["content"] as? String == "Draw the \"door\" states\nplease")
    }

    @Test("REQ-AGT-001, REQ-AGT-010: Decodes claude's events") func decodesEvents() {
        let events = Self.events.split(separator: "\n").flatMap { AgentEvent.decode(String($0)) }
        guard events.count == 7 else {
            Issue.record("expected 7 events, got \(events.count): \(events)")
            return
        }
        guard case let .started(session) = events[0] else { Issue.record("not started: \(events[0])"); return }
        #expect(session.id == "f001a6ac-1407-4a9b-9c49-729e5684e5dd" && session.permissionMode == "dontAsk")
        #expect(session.mcpServers == ["maser": "connected"] && session.tools.count == 6)

        #expect(
            events[1]
                == .toolCall(
                    .init(id: "toolu_013eC6m1he96mb1ZrLzUQf5h", name: "Read", input: #"{"file_path":"/tmp/outside/secret.txt"}"#))
        )
        guard case let .refused(refusal) = events[2], case let .toolResult(denied) = events[3] else {
            Issue.record("expected a refusal and its result: \(events[2...3])")
            return
        }
        #expect(refusal.tool == "Read" && refusal.callID == "toolu_013eC6m1he96mb1ZrLzUQf5h")
        #expect(refusal.message.contains("don't ask mode") && denied.isError)

        guard case let .toolResult(read) = events[4], case let .text(text) = events[5], case let .finished(result) = events[6]
        else { Issue.record("expected a result, text and the end: \(events[4...])"); return }
        #expect(!read.isError && read.text.hasPrefix("1\t// A door controller."))
        #expect(text.hasPrefix("Results:"))
        #expect(result.sessionID == session.id && !result.isError && result.stopReason == "end_turn")
        #expect(result.totalCostUSD == 0.0520376 && result.refusedTools == ["Read"])
    }

    @Test("REQ-AGT-010: Skips what it doesn't use, without failing") func skipsUnknown() {
        for line in [
            "", "not json", #"{"type":"rate_limit_event"}"#, #"{"type":"system","subtype":"hook_started"}"#,
            #"{"type":"something_new","x":1}"#, #"{"type":"result"}"#,
        ] {
            #expect(AgentEvent.decode(line).isEmpty, "\(line)")
        }
        // A user's own message is a plain string, not blocks; it isn't a tool result.
        #expect(AgentEvent.decode(#"{"type":"user","message":{"role":"user","content":"hi"}}"#).isEmpty)
        // Results whose content is a list of text blocks, as MCP tools return.
        let mcp =
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"Shown on the canvas."}]}]}}"#
        #expect(AgentEvent.decode(mcp) == [.toolResult(.init(callID: "t1", isError: false, text: "Shown on the canvas."))])
    }
}
