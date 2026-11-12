// Tests for the review agent's transcript: recording events, per-turn cost, and keeping it across quits.

import Foundation
import Testing

@testable import MaserCore

/// Tests for `AgentTranscript` and `AgentTranscriptStore`.
@Suite struct AgentTranscriptTests {
    /// The end of a turn with a session's running cost.
    static func finished(_ total: Double, session: String = "s1") -> AgentEvent {
        .finished(
            .init(sessionID: session, text: "", isError: false, stopReason: "end_turn", totalCostUSD: total, refusedTools: []))
    }

    @Test("REQ-AGT-010: Fills in each tool call's outcome, and marks refusals") func recordsTools() {
        var transcript = AgentTranscript()
        transcript.record(.toolCall(.init(id: "t1", name: "mcp__maser__pr_context", input: "{}")))
        transcript.record(.toolCall(.init(id: "t2", name: "Read", input: #"{"file_path":"/etc/hosts"}"#)))
        transcript.record(.toolResult(.init(callID: "t1", isError: false, text: "# owner/repo #1")))
        transcript.record(.refused(.init(callID: "t2", tool: "Read", message: "denied in don't ask mode")))
        transcript.record(.toolResult(.init(callID: "t2", isError: true, text: "Permission to use Read has been denied")))
        transcript.record(.toolResult(.init(callID: "unknown", isError: false, text: "ignored")))

        let tools = transcript.entries.compactMap { if case let .tool(use) = $0 { use } else { nil } }
        #expect(tools.count == 2)
        #expect(tools[0].result == "# owner/repo #1" && !tools[0].isError && !tools[0].isRefused)
        #expect(tools[1].isRefused && tools[1].isError && tools[1].result == "Permission to use Read has been denied")
    }

    /// claude reports a running total, even across `--resume`; each turn shows the difference.
    @Test("REQ-AGT-009: Each turn's cost is the change in the running total") func turnCosts() {
        var transcript = AgentTranscript()
        transcript.record(.started(.init(id: "s1", model: nil, tools: [], mcpServers: [:], permissionMode: "dontAsk")))
        transcript.record(Self.finished(0.04))
        transcript.record(Self.finished(0.07))
        // A restarted process for the same session carries on from the session's total.
        transcript.record(Self.finished(0.10))
        let costs = transcript.entries.compactMap { if case let .turnEnded(cost, _, _) = $0 { cost } else { nil } }
        #expect(zip(costs, [0.04, 0.03, 0.03]).allSatisfy { abs($0 - $1) < 0.000_1 })
        #expect(abs(transcript.totalCostUSD - 0.10) < 0.000_1 && transcript.sessionID == "s1")

        // A new session starts its total again; the conversation's total doesn't go down.
        transcript.record(Self.finished(0.02, session: "s2"))
        if case let .turnEnded(cost, _, _) = transcript.entries.last { #expect(cost == 0) }
        #expect(abs(transcript.totalCostUSD - 0.10) < 0.000_1 && transcript.sessionID == "s2")
    }

    @Test("REQ-AGT-001: The conversation survives a quit, and clearing it removes the file") func store() throws {
        let store = AgentTranscriptStore(
            directory: FileManager.default.temporaryDirectory.appending(path: "maser-agent-\(UUID().uuidString)"))
        let pr = try AgentTests.pr("https://github.com/bmannakee/maser/pull/1")
        var transcript = AgentTranscript()
        transcript.entries = [.user("What changed?"), .agent("A door."), .notice("Stopped.")]
        transcript.record(Self.finished(0.05))
        transcript.commit = "4e5b8e054d5da90dc647db34891d6247c454f495"
        transcript.effort = "max"
        try store.save(transcript, for: pr)
        #expect(try store.load(for: pr) == transcript)

        try store.save(AgentTranscript(), for: pr)
        #expect(!FileManager.default.fileExists(atPath: UnsentTextStore(directory: store.directory).fileURL(for: pr).path()))
        #expect(try store.load(for: pr) == AgentTranscript())
    }
}

/// Tests for what the agent is told after drawing.
@Suite struct AgentDiagramReplyTests {
    /// A diagram with one element the drawing lacks, and one citing nothing.
    static func drawn(_ findings: [ElementFinding], cited: Bool = true) -> AgentDiagram {
        AgentDiagram(
            diagram: Diagram(
                title: "Door", format: .mermaid, source: "stateDiagram-v2\n  a --> b",
                elements: [.init(id: "edge1", citation: cited ? "x:1" : nil)]),
            commit: "abc", svg: "<svg/>", findings: findings)
    }

    @Test("REQ-CNV-004: The agent is told what was flagged, and the drawing's IDs when an element isn't among them")
    func reply() {
        let missing = Self.drawn([ElementFinding(id: "edge1", problems: ["isn't in the drawn diagram"])])
        let text = missing.replyText(renderedIDs: ["a", "b", "edge0", "root_start"])
        #expect(text.contains("- edge1 isn't in the drawn diagram"))
        #expect(text.hasSuffix("The drawing's element IDs are: a, b, edge0, root_start."))

        let clean = Self.drawn([ElementFinding(id: "edge1", problems: [])])
        #expect(clean.replyText(renderedIDs: ["a"]) == "Shown on the user's canvas as \"Door\".")
        #expect(Self.drawn([], cited: false).replyText.contains("unsourced"))
    }
}
