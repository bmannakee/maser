// The Files tab of a review window: the changed files, a file's diff, and its review comments.
//
// `FilesView` lays out the file tree, the diff with its vim-style line cursor, and the comments pane, where line
// comments and replies are written. The views hold little state of their own: they read from and act through the
// window's `ReviewModel`.

import AppKit
import MaserCore
import SwiftUI

/// The Files tab: the changed-file tree, the selected file's diff, and its comments, side by side.
struct FilesView: View {
    @Bindable var model: ReviewModel

    var body: some View {
        // Plain fixed-width panes rather than a NavigationSplitView with an inspector: this tab sits in the main
        // window's split view, and both a nested split view and an inspector beside the file tree there send AppKit
        // into an endless constraint-update loop that crashes the app on switching to Files. Fixed widths also keep
        // the diff as wide as possible.
        HStack(spacing: 0) {
            FileTreeView(model: model)
                .listStyle(.sidebar)
                .frame(width: Self.treeWidth(for: model.tree))
            Divider()
            DiffPane(model: model)
                .frame(maxWidth: .infinity)
            if model.showComments {
                Divider()
                CommentsPane(model: model)
                    .frame(width: Self.commentsWidth)
            }
        }
    }

    /// Width of the comments pane: enough for a readable comment, and no more.
    private static let commentsWidth: CGFloat = 320

    /// Returns a width that fits the file tree's widest row, between 160 and 360 points.
    ///
    /// Longer names are truncated in the middle; the full path is in each row's tooltip.
    ///
    /// - Parameter tree: The tree's top-level nodes.
    /// - Returns: The tree pane's width.
    private static func treeWidth(for tree: [FileNode]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest =
            FileTree.rows(in: tree).map { row in
                // List insets, the disclosure indent per level, the icon, and room for a comment-count badge.
                let text = (row.name as NSString).size(withAttributes: [.font: font]).width
                return 20 + CGFloat(row.depth) * 16 + 24 + text + 36
            }.max() ?? 0
        return min(max(widest.rounded(.up), 160), 360)
    }
}

// MARK: - File tree

/// The changed files as a tree of collapsible directories, with the selected file highlighted.
private struct FileTreeView: View {
    let model: ReviewModel

    var body: some View {
        // Route clicks and arrow keys through the model so the line cursor resets per file.
        let selection = Binding<String?> {
            model.selectedPath
        } set: { path in
            if let path { model.select(path: path) }
        }
        List(selection: selection) {
            ForEach(model.tree) { node in
                FileTreeNodeView(node: node, model: model)
            }
        }
        .overlay {
            if case .loaded = model.filesState, model.tree.isEmpty {
                ContentUnavailableView("No changed files", systemImage: "doc")
            }
        }
    }
}

/// One node of the file tree: a directory that expands to its children, or a file row.
private struct FileTreeNodeView: View {
    let node: FileNode
    let model: ReviewModel

    var body: some View {
        if let children = node.children {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(children) { FileTreeNodeView(node: $0, model: model) }
            } label: {
                Label(node.name, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            FileRow(name: node.name, file: model.file(at: node.id), commentCount: model.commentCount(at: node.id))
        }
    }

    /// Whether the directory is expanded, backed by the model's `collapsedDirectories`.
    private var isExpanded: Binding<Bool> {
        Binding {
            !model.collapsedDirectories.contains(node.id)
        } set: { expanded in
            if expanded {
                model.collapsedDirectories.remove(node.id)
            } else {
                model.collapsedDirectories.insert(node.id)
            }
        }
    }
}

/// A changed file in the tree: an icon for its status, its name, and its comment count.
private struct FileRow: View {
    let name: String
    /// The file's diff; nil shows it as modified with no details.
    let file: FileDiff?
    let commentCount: Int

    var body: some View {
        Label {
            Text(name).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .badge(commentCount)
        .help(help)
    }

    /// The SF Symbol for the file's status.
    private var icon: String {
        switch file?.status {
        case .added: "plus.square"
        case .deleted: "minus.square"
        case .renamed: "arrow.right.square"
        case .modified, nil: "doc"
        }
    }

    /// The icon's color for the file's status.
    private var color: Color {
        switch file?.status {
        case .added: .green
        case .deleted: .red
        case .renamed: .orange
        case .modified, nil: .secondary
        }
    }

    /// The tooltip: the full path, lines added and removed, and the old path of a renamed file.
    private var help: String {
        guard let file else { return name }
        var text = "\(file.path)\n+\(file.additions) −\(file.deletions)"
        if let old = file.oldPath { text += "\nrenamed from \(old)" }
        return text
    }
}

// MARK: - Diff

/// The selected file's diff with the key hint bar, or a placeholder while loading, on failure, or with no file.
private struct DiffPane: View {
    let model: ReviewModel

    var body: some View {
        switch model.filesState {
        case .loading:
            ProgressView()
        case let .failed(message):
            ContentUnavailableView(
                "Couldn't load pull request", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded:
            if let file = model.selectedFile {
                VStack(spacing: 0) {
                    DiffView(model: model, file: file)
                        .id(file.id)  // fresh scroll position per file
                    if let status = model.diffNotice ?? model.fullFileStatus {
                        Divider()
                        DiffStatusLine(text: status, isLoading: model.loadingFullFiles.contains(file.path))
                    }
                    Divider()
                    KeyHintBar()
                }
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc.text")
            }
        }
    }
}

/// One file's diff, with the line cursor, selection, and thread markers.
///
/// Carries out the model's scroll requests and reports which lines are visible so the cursor can follow scrolling.
private struct DiffView: View {
    let model: ReviewModel
    let file: FileDiff

    @State private var position = ScrollPosition(edge: .top)
    /// The latest scroll geometry and visible rows.
    ///
    /// They change on every scroll frame, so they live in a reference box rather than view state, which would re-render
    /// the diff each time.
    @State private var scrollState = ScrollState()

    /// Height of one diff row: the monospaced font's line height plus the row's vertical padding.
    private static let rowHeight =
        NSLayoutManager().defaultLineHeight(for: .monospacedSystemFont(ofSize: 12, weight: .regular)) + 2

    var body: some View {
        if file.isBinary {
            ContentUnavailableView("Binary file", systemImage: "doc.zipper", description: Text(file.path))
        } else if file.hunks.isEmpty {
            ContentUnavailableView(
                "No content changes", systemImage: "doc",
                description: Text(file.oldPath.map { "Renamed from \($0)" } ?? file.path))
        } else {
            let markers = model.lineMarkers
            let highlighted = model.highlightedLineIDs
            let cursor = model.cursorLineID
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(file.hunks) { hunk in
                        // The whole file reads as one continuous text, so the hunk headers are left out.
                        if !file.isFullFile {
                            HunkHeaderRow(header: hunk.header)
                        }
                        ForEach(hunk.lines) { line in
                            DiffLineRow(
                                path: file.path,
                                line: line,
                                marker: markers[line.id],
                                isCursor: line.id == cursor,
                                isHighlighted: highlighted?.contains(line.id) ?? false,
                                model: model
                            )
                            // Moving the cursor changes two rows; this keeps the rest from redrawing.
                            .equatable()
                            .id(line.id)
                        }
                    }
                }
                .scrollTargetLayout()
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, new in
                scrollState.geometry = new
            }
            .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.9) { ids in
                scrollState.visibleIDs = Set(ids)
                model.diffVisibilityChanged(ids)
            }
            .onChange(of: model.diffScroll) { _, request in
                if let request { scroll(request.motion) }
            }
            // Handled right away rather than in the task below: holding j or k sends one of these per key repeat.
            .onChange(of: model.scrollRequest) { _, request in
                guard let request, request.path == file.path, request.placement == .nearest else { return }
                bringIntoView(request.lineID)
            }
            // Runs on appear too, so jumping to a thread in another file scrolls once it loads, and going back to a PR
            // in the main window returns to the cursor, however it got there.
            .task(id: model.scrollRequest) {
                // `.nearest` requests are handled by `onChange` above, except the one already there on appear.
                let isFirstRun = !scrollState.hasAppeared
                scrollState.hasAppeared = true
                guard let request = model.scrollRequest, request.path == file.path,
                    request.placement == .center || isFirstRun
                else { return }
                await Task.yield()
                position.scrollTo(id: request.lineID, anchor: .center)
            }
        }
    }
}

extension DiffView {
    /// The diff's latest scroll geometry and visible rows, held where SwiftUI doesn't observe them.
    final class ScrollState {
        /// The latest scroll geometry, for sizing scroll motions.
        var geometry: ScrollGeometry?
        /// The IDs of the rows at least 90% in view, as last reported.
        var visibleIDs: Set<Int> = []
        /// Whether the scroll request task has run once, so later runs know they aren't for the view appearing.
        var hasAppeared = false
    }

    /// Scrolls just far enough to show a line, and not at all if it's already in view.
    ///
    /// The line comes in at the edge it's nearest to, so holding j or k scrolls the diff a row at a time.
    ///
    /// - Parameter lineID: The ID of the line to show.
    private func bringIntoView(_ lineID: Int) {
        let visible = scrollState.visibleIDs
        guard !visible.contains(lineID) else { return }
        // IDs increase down the diff, so comparing them says which way the line is.
        guard let first = visible.min(), let last = visible.max() else {
            position.scrollTo(id: lineID, anchor: .center)
            return
        }
        position.scrollTo(id: lineID, anchor: lineID > last ? .bottom : (lineID < first ? .top : .center))
    }

    /// Scrolls the diff by a vim-style motion, clamped to the content.
    ///
    /// Jumps without animation, like vim, so repeated presses stay predictable. Does nothing until the scroll
    /// geometry is known.
    ///
    /// - Parameter motion: How far to scroll.
    private func scroll(_ motion: ReviewModel.DiffScroll.Motion) {
        guard let geometry = scrollState.geometry else { return }
        let viewport = geometry.visibleRect.height
        let delta: CGFloat
        switch motion {
        case .top: position.scrollTo(edge: .top); return
        case .bottom: position.scrollTo(edge: .bottom); return
        case let .lines(count): delta = CGFloat(count) * Self.rowHeight
        case let .halfPages(count): delta = CGFloat(count) * viewport / 2
        // Keep a couple of rows of overlap so you don't lose your place, as vim does.
        case let .pages(count): delta = CGFloat(count) * max(viewport - 2 * Self.rowHeight, Self.rowHeight)
        }

        let minOffset = -geometry.contentInsets.top
        let maxOffset = geometry.contentSize.height - geometry.containerSize.height + geometry.contentInsets.bottom
        let target = geometry.contentOffset.y + delta
        if target <= minOffset {
            position.scrollTo(edge: .top)
        } else if target >= maxOffset {
            position.scrollTo(edge: .bottom)
        } else {
            position.scrollTo(y: target)
        }
    }
}

/// A line under the diff saying why a key did nothing, or how loading the full file is going.
private struct DiffStatusLine: View {
    let text: String
    /// Whether to show a spinner, while the full file loads.
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "info.circle")
            }
            Text(text).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

/// A hunk's `@@ … @@` header line in the diff.
private struct HunkHeaderRow: View {
    let header: String

    var body: some View {
        Text(header)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.vertical, 4)
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.08))
    }
}

/// One line of the diff: old and new line numbers, a gutter icon, the `+`/`-` sign, and the text.
private struct DiffLineRow: View, Equatable {
    /// The path of the file the line is in.
    let path: String
    let line: DiffLine
    /// Whether a current thread is on this line: nil for none, true if one has a draft comment, false otherwise.
    let marker: Bool?
    let isCursor: Bool
    /// Whether the line is in the `V` selection or covered by the draft comment.
    let isHighlighted: Bool
    let model: ReviewModel

    /// Whether two rows draw the same: the same line and state, in the same window.
    nonisolated static func == (lhs: DiffLineRow, rhs: DiffLineRow) -> Bool {
        lhs.path == rhs.path && lhs.line == rhs.line && lhs.marker == rhs.marker && lhs.isCursor == rhs.isCursor
            && lhs.isHighlighted == rhs.isHighlighted && lhs.model === rhs.model
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Click the line numbers to move the cursor here; shift-click selects a range.
            HStack(spacing: 0) {
                lineNumber(line.oldLine)
                lineNumber(line.newLine)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard line.isCursorStop else { return }
                model.setCursor(line.id, extend: NSEvent.modifierFlags.contains(.shift))
            }
            gutterIcon
                .frame(width: 20)
            Text(sign)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutProbe(probeKey, isText: true)
        }
        .padding(.vertical, 1)
        .layoutProbe(probeKey, isText: false)
        .background(background)
        .overlay {
            if isHighlighted { Color.accentColor.opacity(0.14).allowsHitTesting(false) }
        }
        .overlay(alignment: .leading) {
            if isCursor { Color.accentColor.frame(width: 3).allowsHitTesting(false) }
        }
    }

    /// The row's key in the UI scenarios' layout probe.
    private var probeKey: String { "\(path)#\(line.id)" }

    /// A thread marker, or on a commentable cursor line without a thread, a button to comment on it.
    @ViewBuilder
    private var gutterIcon: some View {
        if let pending = marker {
            Image(systemName: pending ? "text.bubble" : "text.bubble.fill")
                .foregroundStyle(pending ? Color.orange : Color.accentColor)
        } else if isCursor, line.commentSide != nil {
            Button {
                model.startComment()
            } label: {
                Image(systemName: "plus.bubble").foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Comment on this line", .comment)
        } else {
            // A one-line Text, not `Color.clear`: the row aligns on first baselines, and a shape has none, so it would
            // stretch to a wrapped row's height and push the text down into the next row.
            Text(" ")
        }
    }

    /// The line's text, with the "No newline at end of file" marker set apart in italics.
    @ViewBuilder
    private var content: some View {
        if line.kind == .noNewlineMarker {
            Text(line.text).italic().foregroundStyle(.secondary)
        } else {
            // A space keeps empty lines at full row height.
            Text(line.text.isEmpty ? " " : line.text)
        }
    }

    /// Returns a line-number column, blank for a line that doesn't exist on that side.
    ///
    /// - Parameter number: The line number on one side of the diff.
    /// - Returns: A fixed-width, right-aligned number, brighter on the cursor line.
    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(isCursor ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }

    /// The unified-diff sign for the line's kind.
    private var sign: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "-"
        case .context, .noNewlineMarker: ""
        }
    }

    /// The row's tint: green for additions, red for deletions.
    private var background: Color {
        switch line.kind {
        case .addition: .green.opacity(0.15)
        case .deletion: .red.opacity(0.15)
        case .context, .noNewlineMarker: .clear
        }
    }
}

/// A bar listing the main Files-tab keys as currently bound, so they're discoverable.
///
/// Shows each command's first vim-style binding and leaves out commands with none.
private struct KeyHintBar: View {
    /// The hints to show, in order: a label and the commands whose keys go before it.
    private static let hints: [(label: String, commands: [CommandID])] = [
        ("line", [.cursorDown, .cursorUp]),
        ("file", [.previousFile, .nextFile]),
        ("hunk", [.previousHunk, .nextHunk]),
        ("full file", [.toggleFullFile]),
        ("select", [.selectLines]),
        ("comment", [.comment]),
        ("reply", [.reply]),
        ("finish review", [.submitReview]),
        ("all keys", [.showKeybindings]),
    ]

    var body: some View {
        let keymap = ConfigStore.shared.keymap
        HStack(spacing: 14) {
            ForEach(Self.hints, id: \.label) { hint in
                let keys = hint.commands.compactMap { keymap.normal[$0]?.first.map(Keymap.format) }
                if !keys.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(keys, id: \.self) { key in
                            Text(key)
                                .font(.caption.monospaced().weight(.medium))
                                .padding(.horizontal, 4)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                        }
                        Text(hint.label)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

// MARK: - Comments

/// The comments pane: the inline draft's composer, if any, above the selected file's threads.
private struct CommentsPane: View {
    @Bindable var model: ReviewModel

    var body: some View {
        VStack(spacing: 0) {
            if model.inlineDraft != nil {
                InlineComposer(model: model)
                Divider()
            }
            threads
        }
    }

    /// The selected file's threads in a selectable list, or a hint on how to comment when there are none.
    @ViewBuilder
    private var threads: some View {
        let threads = model.selectedThreads
        if threads.isEmpty {
            ContentUnavailableView {
                Label("No comments", systemImage: "bubble.left.and.bubble.right")
            } description: {
                if model.selectedFile == nil {
                    Text("Select a file to see its comments.")
                } else if let keys = ConfigStore.shared.bindingSummary(for: .comment) {
                    Text("Press \(keys) to comment on the cursor line, or click the line numbers to move the cursor.")
                } else {
                    Text("No review comments on this file.")
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            // Selecting a thread (click or arrow keys) scrolls the diff to it; see ReviewModel.focusedThreadID.
            ScrollViewReader { proxy in
                List(threads, selection: $model.focusedThreadID) { thread in
                    ThreadView(thread: thread, model: model)
                }
                .onChange(of: model.focusedThreadID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
        }
    }
}

/// The editor for the inline draft, a line comment or reply.
///
/// ⌘↩ posts it. Esc leaves the box, and leaving an empty draft closes it.
private struct InlineComposer: View {
    @Bindable var model: ReviewModel
    @FocusState private var focused: Bool

    var body: some View {
        if let draft = model.inlineDraft {
            let text = Binding {
                model.inlineDraft?.body ?? ""
            } set: {
                model.inlineDraft?.body = $0
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(draft.title).font(.headline)
                    Spacer()
                    Button("Discard", systemImage: "xmark") { model.discardInlineDraft() }
                        .disabled(draft.isPosting)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Discard this draft")
                }
                TextEditor(text: text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(focused ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: focused ? 2 : 1)
                    }
                    .frame(height: 130)
                    .focused($focused)
                    .disabled(draft.isPosting)

                if let error = draft.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                HStack {
                    Text("Markdown · ⌘↩ · Esc to stop typing")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if draft.isPosting { ProgressView().controlSize(.small) }
                    Button(primaryTitle(draft)) {
                        Task { await model.postInlineDraft() }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.isPosting || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(12)
            .task(id: model.inlineComposerFocusRequest) {
                guard model.inlineComposerFocusRequest else { return }
                model.inlineComposerFocusRequest = false
                focused = true
            }
            .onChange(of: focused) { _, isFocused in
                // Leaving an empty draft closes it.
                if !isFocused, model.inlineDraft?.body.isEmpty == true, model.inlineDraft?.isPosting == false {
                    model.discardInlineDraft()
                }
            }
        }
    }

    /// Returns the post button's title, which says whether the draft will join a pending review.
    ///
    /// - Parameter draft: The draft being written.
    /// - Returns: "Start a review", "Add to review" or "Reply".
    private func primaryTitle(_ draft: ReviewModel.InlineDraft) -> String {
        switch draft.target {
        case .newThread: model.hasPendingReview ? "Add to review" : "Start a review"
        // GitHub puts replies in your pending review if you have one; otherwise they post right away.
        case .reply: model.hasPendingReview ? "Add to review" : "Reply"
        }
    }
}

/// One review thread: where it is, its status tags, and its comments, with buttons to reply and delete drafts.
///
/// Outdated and resolved threads are dimmed.
private struct ThreadView: View {
    let thread: ReviewThread
    let model: ReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(location).font(.caption.bold()).foregroundStyle(.secondary)
                if thread.isPending { Tag(text: "Pending", color: .orange) }
                if thread.isResolved { Tag(text: "Resolved", color: .secondary) }
                Spacer()
                Button("Reply", systemImage: "arrowshape.turn.up.left") {
                    model.startReply(to: thread)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Reply", .reply)
                if let url = thread.root.url {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .help("Open on GitHub")
                }
            }
            ForEach(thread.comments) { comment in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(comment.author).bold()
                        Text("\(comment.createdAt, style: .relative) ago").foregroundStyle(.secondary)
                        if comment.isPending {
                            if !thread.isPending { Tag(text: "Pending", color: .orange) }
                            Spacer()
                            Button("Delete draft", systemImage: "trash") {
                                Task { await model.deletePendingComment(comment) }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Delete this draft comment")
                        }
                    }
                    .font(.caption)
                    Text(markdown(comment.body))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(thread.isOutdated || thread.isResolved ? 0.6 : 1)
    }

    /// The thread's place in the diff, such as "Line 12", "Old lines 3–7" or "Outdated · was line 9".
    private var location: String {
        guard let line = thread.line else {
            return thread.originalLine.map { "Outdated · was line \($0)" } ?? "Outdated"
        }
        let label = CommentTarget.describe(
            side: thread.side, line: line, startSide: thread.startSide, startLine: thread.startLine)
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// Renders a comment's inline Markdown, keeping its line breaks.
    ///
    /// - Parameter body: The comment's Markdown source.
    /// - Returns: The styled text, or the plain source if it doesn't parse.
    private func markdown(_ body: String) -> AttributedString {
        (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(body)
    }
}

/// A small outlined label, such as "Pending" or "Resolved".
private struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(color.opacity(0.6)))
    }
}
