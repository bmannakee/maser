// One PR's conversation with the review agent, as the Agent tab shows it, and the files that keep it across quits.
//
// `claude` keeps its own record of the session, which Maser resumes with `--resume`. Maser keeps what the user saw:
// messages, answers, tool calls and their outcomes, refusals, and costs, plus the session ID, the commit the
// conversation is about, and the model and effort chosen for this PR. `AgentTranscriptStore` writes one JSON file per
// PR, like `UnsentTextStore`.

import Foundation

/// One PR's conversation with the review agent.
public struct AgentTranscript: Codable, Equatable, Sendable {
    /// One item in the conversation.
    public enum Entry: Codable, Equatable, Sendable {
        /// A message from the user.
        case user(String)
        /// Text from the agent.
        case agent(String)
        /// A tool call, and its outcome once known.
        case tool(ToolUse)
        /// The end of a turn, with what it cost.
        case turnEnded(costUSD: Double, isError: Bool, reason: String?)
        /// A note from Maser, such as the PR's head moving or the agent stopping.
        case notice(String)
    }

    /// A tool call and its outcome.
    public struct ToolUse: Codable, Equatable, Sendable {
        /// The call's ID.
        public var id: String
        /// The tool, such as `Read` or `mcp__maser__pr_context`.
        public var name: String
        /// The call's input, as JSON text.
        public var input: String
        /// What it returned, once it has.
        public var result: String?
        /// Whether it failed.
        public var isError = false
        /// Whether it was refused as outside what the agent may do.
        public var isRefused = false

        /// Creates a call with no outcome yet.
        public init(id: String, name: String, input: String) {
            self.id = id
            self.name = name
            self.input = input
        }
    }

    /// The conversation's items, oldest first.
    public var entries: [Entry] = []
    /// The `claude` session to resume, once one has started.
    public var sessionID: String?
    /// The commit the conversation is about: the head of the diff when the last message was sent.
    public var commit: String?
    /// The model chosen for this PR, or nil for the setting's.
    public var model: String?
    /// The effort chosen for this PR, or nil for the setting's.
    public var effort: String?
    /// What the session has cost, in US dollars, as `claude` last reported it.
    public var totalCostUSD = 0.0
    /// The diagrams the agent drew, oldest first.
    public var diagrams: [AgentDiagram] = []
    /// The IDs of the agent's draft comments the user has opened, for Finish Review's question.
    public var openedAgentComments: [String] = []

    /// Creates an empty conversation.
    public init() {}

    /// Records an event from the agent's output.
    ///
    /// A tool result or refusal fills in its call. A finished turn records its cost: the difference from the session's
    /// previous running total, which `claude` reports instead of a per-turn figure.
    ///
    /// - Parameter event: The event.
    public mutating func record(_ event: AgentEvent) {
        switch event {
        case let .started(session):
            sessionID = session.id
        case let .text(text):
            entries.append(.agent(text))
        case let .toolCall(call):
            entries.append(.tool(ToolUse(id: call.id, name: call.name, input: call.input)))
        case let .toolResult(result):
            updateTool(result.callID) {
                $0.result = result.text
                $0.isError = result.isError
            }
        case let .refused(refusal):
            updateTool(refusal.callID) {
                $0.isRefused = true
                $0.isError = true
                if $0.result == nil { $0.result = refusal.message }
            }
        case let .finished(result):
            sessionID = result.sessionID
            let cost = max(0, result.totalCostUSD - totalCostUSD)
            totalCostUSD = max(totalCostUSD, result.totalCostUSD)
            entries.append(.turnEnded(costUSD: cost, isError: result.isError, reason: result.isError ? result.stopReason : nil))
        }
    }

    /// Changes the tool call with an ID, if it's in the conversation.
    ///
    /// - Parameters:
    ///   - id: The call's ID.
    ///   - change: Changes the call in place.
    private mutating func updateTool(_ id: String, _ change: (inout ToolUse) -> Void) {
        guard let index = entries.lastIndex(where: { if case let .tool(use) = $0 { use.id == id } else { false } }),
            case var .tool(use) = entries[index]
        else { return }
        change(&use)
        entries[index] = .tool(use)
    }
}

/// A diagram the agent drew, as the canvas shows it.
public struct AgentDiagram: Codable, Hashable, Identifiable, Sendable {
    /// A unique ID, for choosing it on the canvas.
    public let id: String
    /// What the agent sent.
    public let diagram: Diagram
    /// The commit the diagram describes: the conversation's commit when it was drawn.
    public let commit: String
    /// The rendered SVG, with Maser's marks.
    public let svg: String
    /// What the grounding check found, one per element the agent described.
    public let findings: [ElementFinding]
    /// When it was drawn.
    public let drawnAt: Date

    /// Records a drawn diagram.
    public init(
        id: String = UUID().uuidString, diagram: Diagram, commit: String, svg: String, findings: [ElementFinding],
        drawnAt: Date = .now
    ) {
        self.id = id
        self.diagram = diagram
        self.commit = commit
        self.svg = svg
        self.findings = findings
        self.drawnAt = drawnAt
    }

    /// Whether no element cites any lines, so nothing in it can be checked against the code.
    public var isUnsourced: Bool { !diagram.elements.contains { $0.citation != nil } }
    /// The elements the grounding check found problems with.
    public var flagged: [ElementFinding] { findings.filter { !$0.problems.isEmpty } }

    /// What the agent is told after drawing: that it's shown, and anything flagged, so it can correct it.
    public var replyText: String { replyText(renderedIDs: nil) }

    /// What the agent is told after drawing, listing the drawing's own IDs when some element isn't among them.
    ///
    /// - Parameter renderedIDs: The element IDs the rendered SVG has, if known.
    /// - Returns: The reply.
    public func replyText(renderedIDs: Set<String>?) -> String {
        var lines = ["Shown on the user's canvas as \"\(diagram.title)\"."]
        if isUnsourced {
            lines.append(
                "No element cites source lines, so the user is told it's unsourced. Cite path:start-end for each element.")
        }
        let flagged = flagged
        if !flagged.isEmpty {
            lines.append("Maser flagged these elements to the user; check them and draw again if they're wrong:")
            lines += flagged.map { "- \($0.id) \($0.problems.joined(separator: "; "))" }
            if let renderedIDs, flagged.contains(where: { $0.problems.contains("isn't in the drawn diagram") }) {
                lines.append("The drawing's element IDs are: \(renderedIDs.sorted().joined(separator: ", ")).")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Keeps each PR's `AgentTranscript` in a file.
public struct AgentTranscriptStore: Sendable {
    /// The folder holding the files.
    public let directory: URL

    /// Creates a store in a folder, which is created on the first save.
    ///
    /// - Parameter directory: Where to keep the files.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Reads a PR's conversation.
    ///
    /// - Parameter pr: The pull request.
    /// - Returns: The saved conversation, or an empty one.
    /// - Throws: An error if the file exists but can't be read or decoded.
    public func load(for pr: PullRequest) throws -> AgentTranscript {
        let url = UnsentTextStore(directory: directory).fileURL(for: pr)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return AgentTranscript() }
        return try JSONDecoder().decode(AgentTranscript.self, from: Data(contentsOf: url))
    }

    /// Saves a PR's conversation, or removes its file if the conversation is empty.
    ///
    /// - Parameters:
    ///   - transcript: The conversation.
    ///   - pr: The pull request.
    /// - Throws: An error if the folder or file can't be written.
    public func save(_ transcript: AgentTranscript, for pr: PullRequest) throws {
        let url = UnsentTextStore(directory: directory).fileURL(for: pr)
        if transcript == AgentTranscript() {
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(transcript).write(to: url, options: .atomic)
    }
}
