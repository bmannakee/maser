// The command line Maser runs the review agent with.
//
// The agent is the user's own `claude`, run headless. Everything that confines it is in these arguments: which tools it
// has, which MCP servers and settings it loads, and what it may do without asking. The 2026-11-12 spike checked each
// one (docs/verification/2026-11-12-agent-spike), and the tests pin them, so a change here is a change to risk
// control RC-22.

import Foundation

/// Builds the arguments for running `claude` as the review agent.
public enum AgentCommandLine {
    /// The MCP server name Maser's tools are offered under.
    public static let serverName = "maser"
    /// Maser's own tools, as the MCP server names them.
    public static let maserTools = ["pr_context", "show_diagram", "add_review_comment"]
    /// The built-in tools the agent gets: reading and searching files, nothing else.
    public static let builtInTools = ["Read", "Grep", "Glob"]

    /// Maser's tools as `claude` names them, such as `mcp__maser__pr_context`.
    public static var maserToolNames: [String] { maserTools.map { "mcp__\(serverName)__\($0)" } }

    /// What a session needs besides the settings.
    public struct Options: Equatable, Sendable {
        /// The MCP config file naming Maser's tool server, and nothing else.
        public var mcpConfigPath: String
        /// Maser's instructions, appended to the default system prompt.
        public var systemPrompt: String
        /// The model to use, or nil to leave the choice to the user's own setting.
        public var model: String?
        /// The effort level, or nil to leave the choice to the user's own setting.
        public var effort: AgentSettings.Effort?
        /// The most one turn may spend, in US dollars.
        public var maxBudgetUSD: Double
        /// The session to continue, after a relaunch; nil starts a new one.
        public var resumeSessionID: String?

        /// Creates options for a session.
        public init(
            mcpConfigPath: String, systemPrompt: String, model: String? = nil, effort: AgentSettings.Effort? = nil,
            maxBudgetUSD: Double, resumeSessionID: String? = nil
        ) {
            self.mcpConfigPath = mcpConfigPath
            self.systemPrompt = systemPrompt
            self.model = model
            self.effort = effort
            self.maxBudgetUSD = maxBudgetUSD
            self.resumeSessionID = resumeSessionID
        }
    }

    /// The arguments to run `claude` with, in the checkout as its working directory.
    ///
    /// - Parameter options: The session's options.
    /// - Returns: The arguments, not including `claude` itself.
    public static func arguments(_ options: Options) -> [String] {
        var arguments = [
            "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--tools", builtInTools.joined(separator: ","),
            // No other MCP servers: not the user's, not the PR's .mcp.json, and not the account's claude.ai connectors.
            "--strict-mcp-config", "--mcp-config", options.mcpConfigPath,
            // Never "project" or "local": those load the PR's own .claude/ hooks, settings and CLAUDE.md.
            "--setting-sources", "user",
            // Refuse whatever would need asking. The file tools must not be allowed by name: allowed, they read
            // anywhere the user can; left out, they read only inside the working directory (spike V5).
            "--permission-mode", "dontAsk",
            "--allowedTools",
        ]
        arguments += maserToolNames
        arguments += ["--max-budget-usd", String(format: "%.2f", options.maxBudgetUSD)]
        if let model = options.model { arguments += ["--model", model] }
        if let effort = options.effort { arguments += ["--effort", effort.rawValue] }
        if let session = options.resumeSessionID { arguments += ["--resume", session] }
        arguments += ["--append-system-prompt", options.systemPrompt]
        return arguments
    }

    /// One user message as a line of stream-json input.
    ///
    /// - Parameter text: The message.
    /// - Returns: The JSON line, ending in a newline.
    public static func messageLine(_ text: String) -> String {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        // The dictionary holds only strings, so it always serializes.
        let data =
            (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
