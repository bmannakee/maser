import AppKit
import MaserCore
import SwiftUI

/// The Files tab: changed files | diff | comments (inspector).
struct FilesView: View {
    @Bindable var model: ReviewModel

    var body: some View {
        NavigationSplitView {
            FileTreeView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 260, max: 500)
        } detail: {
            DiffPane(model: model)
        }
        .inspector(isPresented: $model.showComments) {
            CommentsPane(model: model)
                .inspectorColumnWidth(min: 240, ideal: 340, max: 600)
        }
    }
}

// MARK: - File tree

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

private struct FileRow: View {
    let name: String
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

    private var icon: String {
        switch file?.status {
        case .added: "plus.square"
        case .deleted: "minus.square"
        case .renamed: "arrow.right.square"
        case .modified, nil: "doc"
        }
    }

    private var color: Color {
        switch file?.status {
        case .added: .green
        case .deleted: .red
        case .renamed: .orange
        case .modified, nil: .secondary
        }
    }

    private var help: String {
        guard let file else { return name }
        var text = "\(file.path)\n+\(file.additions) −\(file.deletions)"
        if let old = file.oldPath { text += "\nrenamed from \(old)" }
        return text
    }
}

// MARK: - Diff

private struct DiffPane: View {
    let model: ReviewModel

    var body: some View {
        switch model.filesState {
        case .loading:
            ProgressView()
        case let .failed(message):
            ContentUnavailableView("Couldn't load pull request", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded:
            if let file = model.selectedFile {
                DiffView(model: model, file: file)
                    .id(file.id) // fresh scroll position per file
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc.text")
            }
        }
    }
}

private struct DiffView: View {
    let model: ReviewModel
    let file: FileDiff

    @State private var position = ScrollPosition(edge: .top)
    /// Updated on every scroll frame; kept out of view state so scrolling doesn't re-render the diff.
    @State private var geometry = GeometryBox()

    /// Height of one diff row: the monospaced font's line height plus the row's vertical padding.
    private static let rowHeight = NSLayoutManager().defaultLineHeight(for: .monospacedSystemFont(ofSize: 12, weight: .regular)) + 2

    var body: some View {
        if file.isBinary {
            ContentUnavailableView("Binary file", systemImage: "doc.zipper", description: Text(file.path))
        } else if file.hunks.isEmpty {
            ContentUnavailableView("No content changes", systemImage: "doc", description: Text(file.oldPath.map { "Renamed from \($0)" } ?? file.path))
        } else {
            let markers = model.lineMarkers
            let highlighted = model.highlightedLineIDs
            let cursor = model.cursorLineID
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(file.hunks) { hunk in
                            HunkHeaderRow(header: hunk.header)
                            ForEach(hunk.lines) { line in
                                DiffLineRow(
                                    line: line,
                                    marker: markers[line.id],
                                    isCursor: line.id == cursor,
                                    isHighlighted: highlighted?.contains(line.id) ?? false,
                                    model: model
                                )
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
                    geometry.value = new
                }
                .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.9) { ids in
                    model.diffVisibilityChanged(ids)
                }
                .onChange(of: model.diffScroll) { _, request in
                    if let request { scroll(request.motion) }
                }
                // Runs on appear too, so jumping to a thread in another file scrolls once it loads.
                .task(id: model.scrollRequest) {
                    guard let request = model.scrollRequest, request.path == file.path else { return }
                    await Task.yield()
                    switch request.placement {
                    case .center: proxy.scrollTo(request.lineID, anchor: .center)
                    case .nearest: proxy.scrollTo(request.lineID) // just enough to bring it into view
                    }
                }
            }
        }
    }
}

extension DiffView {
    final class GeometryBox {
        var value: ScrollGeometry?
    }

    /// Vim-style motions. Jumps without animation, like vim, so repeated presses stay predictable.
    private func scroll(_ motion: ReviewModel.DiffScroll.Motion) {
        guard let geometry = geometry.value else { return }
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

private struct DiffLineRow: View {
    let line: DiffLine
    /// nil: no thread here; true: a thread with a draft comment.
    let marker: Bool?
    let isCursor: Bool
    let isHighlighted: Bool
    let model: ReviewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Click the line numbers to move the cursor here; shift-click selects a range.
            HStack(spacing: 0) {
                lineNumber(line.oldLine)
                lineNumber(line.newLine)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard line.commentSide != nil else { return }
                model.setCursor(line.id, extend: NSEvent.modifierFlags.contains(.shift))
            }
            gutterIcon
                .frame(width: 20)
            Text(sign)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .background(background)
        .overlay {
            if isHighlighted { Color.accentColor.opacity(0.14).allowsHitTesting(false) }
        }
        .overlay(alignment: .leading) {
            if isCursor { Color.accentColor.frame(width: 3).allowsHitTesting(false) }
        }
    }

    @ViewBuilder
    private var gutterIcon: some View {
        if let pending = marker {
            Image(systemName: pending ? "text.bubble" : "text.bubble.fill")
                .foregroundStyle(pending ? Color.orange : Color.accentColor)
        } else if isCursor {
            Button {
                model.startComment()
            } label: {
                Image(systemName: "plus.bubble").foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Comment on this line", .comment)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var content: some View {
        if line.kind == .noNewlineMarker {
            Text(line.text).italic().foregroundStyle(.secondary)
        } else {
            Text(line.text.isEmpty ? " " : line.text)
        }
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(isCursor ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var sign: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "-"
        case .context, .noNewlineMarker: ""
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: .green.opacity(0.15)
        case .deletion: .red.opacity(0.15)
        case .context, .noNewlineMarker: .clear
        }
    }
}

// MARK: - Comments

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

/// The draft line comment or reply. ⌘↩ adds it; Esc leaves the box (an empty draft then closes).
private struct InlineComposer: View {
    @Bindable var model: ReviewModel
    @FocusState private var focused: Bool

    var body: some View {
        if let draft = model.inlineDraft {
            let text = Binding { model.inlineDraft?.body ?? "" } set: { model.inlineDraft?.body = $0 }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(draft.title).font(.headline)
                    Spacer()
                    Button("Discard", systemImage: "xmark") { model.discardInlineDraft() }
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

    private func primaryTitle(_ draft: ReviewModel.InlineDraft) -> String {
        switch draft.target {
        case .newThread: model.hasPendingReview ? "Add to review" : "Start a review"
        // GitHub puts replies in your pending review if you have one; otherwise they post right away.
        case .reply: model.hasPendingReview ? "Add to review" : "Reply"
        }
    }
}

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

    private var location: String {
        guard let line = thread.line else {
            return thread.originalLine.map { "Outdated · was line \($0)" } ?? "Outdated"
        }
        let prefix = thread.side == .left ? "Old line" : "Line"
        if let start = thread.startLine, start != line { return "\(prefix)s \(start)–\(line)" }
        return "\(prefix) \(line)"
    }

    private func markdown(_ body: String) -> AttributedString {
        (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(body)
    }
}

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
