// The events the review agent's `claude` process prints, one JSON object per line.
//
// `claude --output-format stream-json` prints an `init` event, then for each turn the assistant's text and tool calls,
// the tool results, any refusals, and a final `result` with the turn's answer, cost and session. `AgentEvent.decode`
// turns one line into the few things Maser shows, and skips anything else, so a new event type in a later `claude`
// doesn't break the conversation. Shapes are the ones recorded in the 2026-11-12 spike.

import Foundation

/// One event from the agent's output that Maser acts on.
public enum AgentEvent: Equatable, Sendable {
    /// The session started.
    case started(Session)
    /// The agent wrote some text.
    case text(String)
    /// The agent called a tool.
    case toolCall(ToolCall)
    /// A tool call finished.
    case toolResult(ToolResult)
    /// A tool call was refused, because it was outside what the agent may do.
    case refused(Refusal)
    /// A turn finished.
    case finished(Result)

    /// What `claude` reports when a session starts.
    public struct Session: Equatable, Sendable {
        /// The session's ID, for `--resume`.
        public let id: String
        /// The model in use.
        public let model: String?
        /// The tools the agent has.
        public let tools: [String]
        /// The MCP servers, with their status, such as `maser: connected`.
        public let mcpServers: [String: String]
        /// The permission mode, which should be `dontAsk`.
        public let permissionMode: String?
    }

    /// A tool call.
    public struct ToolCall: Equatable, Sendable {
        /// The call's ID, which its result and any refusal name.
        public let id: String
        /// The tool, such as `Read` or `mcp__maser__pr_context`.
        public let name: String
        /// The call's input as JSON text, to show the user what was asked for.
        public let input: String
    }

    /// The outcome of a tool call.
    public struct ToolResult: Equatable, Sendable {
        /// The ID of the call.
        public let callID: String
        /// Whether the call failed or was refused.
        public let isError: Bool
        /// What the tool returned, as text.
        public let text: String
    }

    /// A refused tool call.
    public struct Refusal: Equatable, Sendable {
        /// The ID of the call.
        public let callID: String
        /// The tool.
        public let tool: String
        /// Why, as `claude` puts it.
        public let message: String
    }

    /// The end of a turn.
    public struct Result: Equatable, Sendable {
        /// The session's ID.
        public let sessionID: String
        /// The turn's final answer.
        public let text: String
        /// Whether the turn failed, for example on reaching the spending cap.
        public let isError: Bool
        /// Why it ended, such as `end_turn`, or the error subtype.
        public let stopReason: String?
        /// What the session has cost so far, in US dollars; a running total, even across a resume.
        public let totalCostUSD: Double
        /// The tools refused during the turn.
        public let refusedTools: [String]
    }

    /// Decodes one line of the agent's output.
    ///
    /// - Parameter line: One line of stream-json output.
    /// - Returns: The events it holds, in order: one assistant message can hold text and several tool calls. Empty for
    ///   lines Maser doesn't act on, and for lines that aren't valid JSON.
    public static func decode(_ line: String) -> [AgentEvent] {
        guard let data = line.data(using: .utf8), let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            return []
        }
        switch (raw.type, raw.subtype) {
        case ("system", "init"):
            guard let id = raw.session_id else { return [] }
            let servers = Dictionary(
                (raw.mcp_servers ?? []).map { ($0.name, $0.status ?? "unknown") }, uniquingKeysWith: { first, _ in first })
            return [
                .started(
                    Session(
                        id: id, model: raw.model, tools: raw.tools ?? [], mcpServers: servers, permissionMode: raw.permissionMode)
                )
            ]
        case ("system", "permission_denied"):
            guard let callID = raw.tool_use_id, let tool = raw.tool_name else { return [] }
            return [.refused(Refusal(callID: callID, tool: tool, message: raw.message?.text ?? ""))]
        case ("assistant", _):
            return (raw.message?.blocks ?? []).compactMap { block in
                switch block.type {
                case "text": block.text.map(AgentEvent.text)
                case "tool_use":
                    block.id.flatMap { id in
                        block.name.map { .toolCall(ToolCall(id: id, name: $0, input: block.input?.jsonText ?? "{}")) }
                    }
                default: nil
                }
            }
        case ("user", _):
            return (raw.message?.blocks ?? []).compactMap { block in
                guard block.type == "tool_result", let callID = block.tool_use_id else { return nil }
                return .toolResult(ToolResult(callID: callID, isError: block.is_error ?? false, text: block.content?.text ?? ""))
            }
        case ("result", _):
            guard let sessionID = raw.session_id else { return [] }
            return [
                .finished(
                    Result(
                        sessionID: sessionID, text: raw.result ?? "", isError: raw.is_error ?? false,
                        stopReason: raw.stop_reason ?? raw.subtype, totalCostUSD: raw.total_cost_usd ?? 0,
                        refusedTools: (raw.permission_denials ?? []).compactMap(\.tool_name)))
            ]
        default:
            return []
        }
    }

    // MARK: - The JSON as printed

    /// The fields of any event that Maser reads; every one is optional, so unknown shapes decode as empty.
    private struct Raw: Decodable {
        let type: String
        let subtype: String?
        let session_id: String?
        let model: String?
        let tools: [String]?
        let mcp_servers: [Server]?
        let permissionMode: String?
        let tool_name: String?
        let tool_use_id: String?
        let message: Message?
        let result: String?
        let is_error: Bool?
        let stop_reason: String?
        let total_cost_usd: Double?
        let permission_denials: [Denial]?
    }

    /// An MCP server in the `init` event.
    private struct Server: Decodable {
        let name: String
        let status: String?
    }

    /// A refused call in a `result` event.
    private struct Denial: Decodable {
        let tool_name: String?
    }

    /// A `message` field: an assistant or user message, or the text of a `permission_denied` event.
    private enum Message: Decodable {
        case text(String)
        case message([Block])

        /// The content blocks, for a message.
        var blocks: [Block]? {
            if case let .message(blocks) = self { return blocks }
            return nil
        }
        /// The text, for a plain string.
        var text: String? {
            if case let .text(text) = self { return text }
            return nil
        }

        init(from decoder: any Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self = .text(text)
                return
            }
            let content = try decoder.container(keyedBy: CodingKeys.self).decode(Content.self, forKey: .content)
            self = .message(content.blocks)
        }

        private enum CodingKeys: String, CodingKey { case content }
    }

    /// A message's content: a list of blocks, or a plain string (as a user's own message is).
    private struct Content: Decodable {
        let blocks: [Block]

        init(from decoder: any Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                blocks = [Block(type: "text", text: text)]
            } else {
                blocks = try decoder.singleValueContainer().decode([Block].self)
            }
        }
    }

    /// One content block: text, a tool call, or a tool result.
    private struct Block: Decodable {
        var type: String
        var text: String?
        var id: String?
        var name: String?
        var input: JSONValue?
        var tool_use_id: String?
        var is_error: Bool?
        var content: JSONValue?

        init(type: String, text: String) {
            self.type = type
            self.text = text
        }
    }
}

/// Any JSON value, kept so a tool call's input or result can be shown as it was.
enum JSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    /// The value as compact JSON text, with keys sorted.
    var jsonText: String {
        let data =
            (try? JSONSerialization.data(
                withJSONObject: foundationValue, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The text a tool result shows: a string as is, or the text blocks of a list joined.
    var text: String {
        switch self {
        case let .string(text): text
        case let .array(items):
            items.compactMap { item -> String? in
                guard case let .object(fields) = item, case let .string(text)? = fields["text"] else { return nil }
                return text
            }.joined(separator: "\n")
        default: jsonText
        }
    }

    /// The value as Foundation objects, for `JSONSerialization`.
    private var foundationValue: Any {
        switch self {
        case let .string(value): value
        case let .number(value): value
        case let .bool(value): value
        case .null: NSNull()
        case let .array(values): values.map(\.foundationValue)
        case let .object(fields): fields.mapValues(\.foundationValue)
        }
    }
}
