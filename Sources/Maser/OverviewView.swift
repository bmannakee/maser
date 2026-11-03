// The Overview tab of a review window.
//
// Shows the PR's title and branches, its conversation (rendered by `ConversationHTML` into an `HTMLView`), a box for
// posting a new comment, and a sidebar with merge status, reviews, checks and labels.

import MaserCore
import SwiftUI

/// The Overview tab: header, conversation (description, comments, reviews) and a status sidebar.
struct OverviewView: View {
    let model: ReviewModel

    var body: some View {
        switch model.overviewState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView("Couldn't load overview", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded:
            if let overview = model.overview {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        OverviewHeader(overview: overview)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                        Divider()
                        HTMLView(
                            html: model.conversationHTML,
                            baseURL: overview.url,
                            scrollToEnd: model.conversationScrollToEnd,
                            onQuote: { model.quoteReply(to: $0) }
                        )
                        Divider()
                        CommentComposer(model: model)
                    }
                    Divider()
                    ScrollView {
                        StatusSidebar(overview: overview)
                            .padding(16)
                    }
                    .frame(width: 300)
                }
                .task {
                    // Keep "5 minutes ago" true while the conversation is showing.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        model.refreshConversationTimes()
                    }
                }
            }
        }
    }
}

// MARK: - Comment composer

/// A Markdown comment box under the conversation.
///
/// Grows while it's focused or has a draft or error; ⌘↩ posts, Esc leaves it. Focuses itself when the model asks
/// (`composerFocusRequest`), as the `comment` command and "Quote reply" do.
private struct CommentComposer: View {
    @Bindable var model: ReviewModel
    @FocusState private var focused: Bool

    var body: some View {
        let expanded = focused || !model.commentDraft.isEmpty || model.commentError != nil
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.commentDraft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: focused ? 2 : 1)
                }
                .overlay(alignment: .topLeading) {
                    if model.commentDraft.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 9)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: expanded ? 150 : 32)
                .focused($focused)
                .disabled(model.isPostingComment)

            if expanded {
                HStack(spacing: 10) {
                    if let error = model.commentError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    } else {
                        Text("Markdown · ⌘↩ to comment · Esc to stop typing")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isPostingComment {
                        ProgressView().controlSize(.small)
                    }
                    Button("Comment") {
                        Task { await model.postComment() }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.isPostingComment || model.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .font(.callout)
            }
        }
        .padding(12)
        .animation(.snappy(duration: 0.15), value: expanded)
        // Runs on appear too, so a request made before the box was showing (say, while the overview was still loading)
        // focuses it once it appears.
        .task(id: model.composerFocusRequest) {
            guard model.composerFocusRequest else { return }
            model.composerFocusRequest = false
            focused = true
        }
    }

    /// The empty-box prompt, including the keys that focus it.
    private var placeholder: String {
        if let keys = ConfigStore.shared.bindingSummary(for: .comment) {
            "Leave a comment (\(keys))"
        } else {
            "Leave a comment"
        }
    }
}

// MARK: - Header

/// The PR's title, state, branches and diff size.
private struct OverviewHeader: View {
    let overview: PullRequestOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(overview.title)
                .font(.title2.bold())
                .textSelection(.enabled)
            HStack(spacing: 8) {
                StatePill(overview: overview)
                Text("**\(overview.author)** wants to merge into")
                RefName(name: overview.baseRef)
                Text("from")
                RefName(name: overview.headRef)
                Spacer(minLength: 16)
                Text("+\(overview.additions)").foregroundStyle(.green)
                Text("−\(overview.deletions)").foregroundStyle(.red)
                Text("\(overview.changedFiles) files").foregroundStyle(.secondary)
            }
            .font(.callout)
            .lineLimit(1)
        }
    }
}

/// A branch name in monospace on a tinted background, truncated in the middle when long.
private struct RefName: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.callout.monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

/// A colored capsule with the PR's state, like github.com's: Open, Draft, Merged or Closed.
private struct StatePill: View {
    let overview: PullRequestOverview

    var body: some View {
        Label(title, systemImage: icon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }

    private var title: String {
        switch overview.state {
        case .merged: "Merged"
        case .closed: "Closed"
        case .open: overview.isDraft ? "Draft" : "Open"
        }
    }

    private var icon: String {
        switch overview.state {
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .open: overview.isDraft ? "pencil.circle" : "arrow.triangle.pull"
        }
    }

    private var color: Color {
        switch overview.state {
        case .merged: .purple
        case .closed: .red
        case .open: overview.isDraft ? .gray : .green
        }
    }
}

// MARK: - Sidebar

/// The sidebar's merge status, reviews, checks and labels.
private struct StatusSidebar: View {
    let overview: PullRequestOverview

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SidebarSection("Merge") {
                StatusRow(merge.title, systemImage: merge.icon, color: merge.color)
            }

            SidebarSection("Reviews") {
                if let decision = overview.reviewDecision {
                    let (title, icon, color) = Self.describe(decision)
                    StatusRow(title, systemImage: icon, color: color)
                }
                ForEach(overview.reviewerStatuses, id: \.author) { status in
                    let (title, icon, color) = Self.describe(status.state)
                    StatusRow(status.author, systemImage: icon, color: color).help(title)
                }
                ForEach(overview.requestedReviewers, id: \.self) { reviewer in
                    StatusRow(reviewer, systemImage: "circle.dotted", color: .orange).help("Review requested")
                }
                if overview.reviewDecision == nil, overview.reviewerStatuses.isEmpty, overview.requestedReviewers.isEmpty {
                    Text("No reviews").foregroundStyle(.secondary)
                }
            }

            SidebarSection("Checks") {
                if overview.checks.isEmpty {
                    Text("No checks").foregroundStyle(.secondary)
                } else {
                    Text(checksSummary).foregroundStyle(.secondary).font(.callout)
                    ForEach(overview.checks) { CheckRow(check: $0) }
                }
            }

            if !overview.labels.isEmpty {
                SidebarSection("Labels") {
                    ForEach(overview.labels, id: \.name) { label in
                        Text(label.name)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color(hex: label.color).opacity(0.3), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color(hex: label.color)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// How the merge status reads in the sidebar.
    ///
    /// A conflict reported by `mergeable` wins over whatever `mergeState` says.
    private var merge: (title: String, icon: String, color: Color) {
        switch overview.state {
        case .merged: return ("Merged", "arrow.triangle.merge", .purple)
        case .closed: return ("Closed without merging", "xmark.circle.fill", .red)
        case .open: break
        }
        if overview.mergeable == .conflicting {
            return ("Has merge conflicts", "exclamationmark.triangle.fill", .red)
        }
        return switch overview.mergeState {
        case .clean, .hasHooks: ("Ready to merge", "checkmark.circle.fill", .green)
        case .dirty: ("Has merge conflicts", "exclamationmark.triangle.fill", .red)
        case .blocked: ("Blocked by branch protection", "hand.raised.fill", .orange)
        case .behind: ("Branch is out of date", "arrow.down.circle.fill", .orange)
        case .unstable: ("Mergeable, some checks failing", "exclamationmark.circle.fill", .orange)
        case .draft: ("Draft — not ready to merge", "pencil.circle.fill", .gray)
        case .unknown: ("Checking mergeability…", "clock.fill", .secondary)
        }
    }

    /// Counts of checks by outcome, worst first, such as "1 failed, 2 pending, 10 passed".
    private var checksSummary: String {
        let counts = Dictionary(grouping: overview.checks, by: \.state).mapValues(\.count)
        let parts: [(CheckState, String)] = [
            (.failure, "failed"), (.pending, "pending"), (.cancelled, "cancelled"),
            (.neutral, "neutral"), (.success, "passed"), (.skipped, "skipped"),
        ]
        return parts.compactMap { state, word in counts[state].map { "\($0) \(word)" } }.joined(separator: ", ")
    }

    /// The title, SF Symbol and color for the PR's overall review decision.
    private static func describe(_ decision: PullRequestOverview.ReviewDecision) -> (String, String, Color) {
        switch decision {
        case .approved: ("Approved", "checkmark.circle.fill", .green)
        case .changesRequested: ("Changes requested", "exclamationmark.bubble.fill", .red)
        case .reviewRequired: ("Review required", "eye.circle.fill", .orange)
        }
    }

    /// The title, SF Symbol and color for one reviewer's latest verdict.
    private static func describe(_ state: Review.State) -> (String, String, Color) {
        switch state {
        case .approved: ("Approved", "checkmark.circle.fill", .green)
        case .changesRequested: ("Requested changes", "exclamationmark.bubble.fill", .red)
        case .commented: ("Commented", "bubble.left.fill", .secondary)
        case .dismissed: ("Review dismissed", "minus.circle", .secondary)
        }
    }
}

/// A titled group in the sidebar.
private struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    /// Creates a section with a headline title above its content.
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
        }
    }
}

/// A sidebar line: text with a tinted SF Symbol.
private struct StatusRow: View {
    let title: String
    let systemImage: String
    let color: Color

    /// Creates a row showing `title` next to the `systemImage` symbol tinted `color`.
    init(_ title: String, systemImage: String, color: Color) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
    }
}

/// One CI check with its status icon and detail; links to the check's page when it has one.
private struct CheckRow: View {
    let check: Check

    var body: some View {
        let row = Label {
            VStack(alignment: .leading, spacing: 0) {
                Text(check.name).lineLimit(1).truncationMode(.middle)
                if let detail = check.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .help(check.name)

        if let url = check.url {
            Link(destination: url) { row }.buttonStyle(.plain)
        } else {
            row
        }
    }

    private var icon: String {
        switch check.state {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "clock.fill"
        case .cancelled: "xmark.circle"
        case .neutral: "minus.circle"
        case .skipped: "slash.circle"
        }
    }

    private var color: Color {
        switch check.state {
        case .success: .green
        case .failure: .red
        case .pending: .orange
        case .cancelled, .neutral, .skipped: .secondary
        }
    }
}

private extension Color {
    /// A color from a six-digit hex string without `#`, such as GitHub's label color `"d73a4a"`.
    ///
    /// Malformed strings give gray.
    init(hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
