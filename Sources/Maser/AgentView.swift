// The Agent tab: the conversation with the review agent about the open PR.
//
// When the agent is off for the PR, the tab says why and which setting allows it. Otherwise it shows what the agent can
// read (repository, commit, checkout) and the model, effort and cost, then the conversation (messages, answers, every
// tool call with its input and outcome, refusals, and Maser's notes), and a message box: ⌘↩ sends, Esc leaves it.
// The canvas with the agent's diagrams (`CanvasView`) sits beside the conversation; `i` hides it.

import MaserCore
import SwiftUI

/// The review agent's conversation for one PR.
struct AgentView: View {
    @Bindable var model: ReviewModel

    var body: some View {
        let agent = model.agent
        if let rule = agent.allowRule {
            VStack(spacing: 0) {
                AgentHeader(agent: agent, rule: rule, head: model.diffCommitID)
                Divider()
                if agent.isStale, let old = agent.transcript.commit, let new = model.diffCommitID {
                    let note =
                        "This conversation is about \(old.prefix(7)); the PR's head is now \(new.prefix(7)). Your next message moves the agent to the new commit."
                    Label(note, systemImage: "clock.arrow.circlepath")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.Brand.beamWash)
                        .shownText("agent-stale", note)
                }
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        AgentConversation(agent: agent)
                        Divider()
                        AgentComposer(agent: agent)
                    }
                    .frame(minWidth: 320, idealWidth: 420, maxWidth: agent.showsCanvas ? 480 : .infinity)
                    if agent.showsCanvas {
                        Divider()
                        CanvasView(agent: agent, head: model.diffCommitID)
                            .frame(minWidth: 320, maxWidth: .infinity)
                    }
                }
            }
        } else {
            let owner = model.pr.repository.nameWithOwner.split(separator: "/").first.map(String.init) ?? ""
            let entry = model.pr.host == "github.com" ? owner : "\(model.pr.host)/\(owner)"
            let message =
                "To let it read this PR, add \"\(entry)\" to [agent] allow in config.toml (⌘,). Allow only code whose owner lets you send it to the model provider."
            ContentUnavailableView {
                Label("The agent is off for \(model.pr.repository.nameWithOwner)", systemImage: "lock")
            } description: {
                Text(message)
                    .shownText("agent-off", message)
            }
        }
    }
}

/// What the agent can read, and the model, effort and cost.
private struct AgentHeader: View {
    let agent: AgentSession
    let rule: AgentSettings.AllowRule
    let head: String?

    var body: some View {
        let commit = (agent.transcript.commit ?? head).map { String($0.prefix(7)) } ?? "…"
        let scope = "Reads \(agent.pr.repository.nameWithOwner) at \(commit), read-only (allowed by \"\(rule)\")"
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(scope)
                    .shownText("agent-scope", scope)
                if let path = agent.checkoutPath {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Menu(agent.model ?? "Default model") {
                Button("Default (\(ConfigStore.shared.settings.agent.model ?? "claude's own"))") { agent.setModel(nil) }
                Divider()
                ForEach(["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"], id: \.self) { name in
                    Button(name) { agent.setModel(name) }
                }
            }
            .fixedSize()
            .shownText("agent-model", agent.model ?? "default")
            Menu("Effort: \(agent.effort?.rawValue ?? "default")") {
                Button("Default") { agent.setEffort(nil) }
                Divider()
                ForEach(AgentSettings.Effort.allCases, id: \.self) { level in
                    Button(level.rawValue) { agent.setEffort(level) }
                }
            }
            .fixedSize()
            .shownText("agent-effort", agent.effort?.rawValue ?? "default")
            let cost = String(format: "$%.2f", agent.transcript.totalCostUSD)
            Text(cost)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("What this conversation has cost so far")
                .shownText("agent-cost", cost)
            Button("Clear", systemImage: "trash") { agent.clear() }
                .labelStyle(.iconOnly)
                .help("Clear this conversation")
                .disabled(agent.transcript.entries.isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The conversation, scrolled to its end as it grows.
private struct AgentConversation: View {
    let agent: AgentSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if agent.transcript.entries.isEmpty {
                        Text(
                            "Ask about this PR. The agent can read the repository at the PR's head commit and the PR itself. It can't change anything."
                        )
                        .foregroundStyle(.secondary)
                    }
                    ForEach(Array(agent.transcript.entries.enumerated()), id: \.offset) { _, entry in
                        AgentEntryView(entry: entry)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: agent.transcript.entries.count) {
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// One item of the conversation.
private struct AgentEntryView: View {
    let entry: AgentTranscript.Entry

    var body: some View {
        switch entry {
        case let .user(text):
            Text(text)
                .textSelection(.enabled)
                .padding(8)
                .background(Color.Brand.rubyWash, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case let .agent(text):
            Text(Self.markdown(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .tool(use):
            AgentToolView(use: use)
        case let .turnEnded(cost, isError, reason):
            Text(
                isError ? "Turn failed (\(reason ?? "error")) · \(String(format: "$%.2f", cost))" : String(format: "$%.2f", cost)
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(isError ? Color.Brand.delInk : .secondary)
        case let .notice(text):
            Label(text, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// The agent's Markdown, with line breaks kept; plain text if it doesn't parse.
    ///
    /// - Parameter text: The Markdown.
    /// - Returns: The styled text.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// A tool call: the tool, its input, and its outcome, which expands to show what it returned.
private struct AgentToolView: View {
    let use: AgentTranscript.ToolUse
    @State private var expanded = false

    var body: some View {
        let name = use.name.replacingOccurrences(of: "mcp__maser__", with: "")
        let icon =
            use.isRefused
            ? "hand.raised.fill" : use.result == nil ? "hourglass" : use.isError ? "xmark.circle" : "checkmark.circle"
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(use.isRefused || use.isError ? Color.Brand.delInk : .secondary)
                    Text(name).bold()
                    Text(use.input)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if use.isRefused {
                        Text("refused").foregroundStyle(Color.Brand.delInk)
                    }
                }
                .font(.callout.monospaced())
            }
            .buttonStyle(.plain)
            if expanded, let result = use.result {
                Text(result)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(40)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            }
        }
    }
}

/// The message box, with Send and Stop.
private struct AgentComposer: View {
    @Bindable var agent: AgentSession
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $agent.draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(focused ? Color.Brand.ruby : Color.secondary.opacity(0.35), lineWidth: focused ? 2 : 1)
                }
                .overlay(alignment: .topLeading) {
                    if agent.draft.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 9)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 80)
                .focused($focused)
            HStack(spacing: 10) {
                switch agent.status {
                case let .preparing(step):
                    ProgressView().controlSize(.small)
                    Text(step).foregroundStyle(.secondary).shownText("agent-status", step)
                case .answering:
                    ProgressView().controlSize(.small)
                    Text("Answering…").foregroundStyle(.secondary).shownText("agent-status", "answering")
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.Brand.delInk)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .shownText("agent-status", message)
                case .idle:
                    Text("⌘↩ to send · Esc to stop typing").foregroundStyle(.secondary)
                }
                Spacer()
                if agent.status == .answering || agent.isPreparing {
                    Button("Stop") { agent.stop() }
                }
                Button("Send") {
                    Task { await agent.send() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!agent.canSend)
            }
            .font(.callout)
        }
        .padding(12)
        // Runs on appear too, so a request made before the tab showed focuses the box once it does.
        .task(id: agent.focusRequest) {
            guard agent.focusRequest else { return }
            agent.focusRequest = false
            focused = true
        }
    }

    /// The empty-box prompt, including the keys that focus it.
    private var placeholder: String {
        if let keys = ConfigStore.shared.bindingSummary(for: .comment) {
            "Ask about this PR (\(keys))"
        } else {
            "Ask about this PR"
        }
    }
}
