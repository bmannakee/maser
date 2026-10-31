import MaserCore
import SwiftUI

/// Three-pane review window: changed files | diff | comments (inspector).
struct ReviewView: View {
    @State private var model: ReviewModel
    @State private var showComments = true
    @Environment(\.openURL) private var openURL

    init(pr: PullRequest) {
        _model = State(initialValue: ReviewModel(pr: pr))
    }

    var body: some View {
        NavigationSplitView {
            FileTreeView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 260, max: 500)
        } detail: {
            DiffPane(model: model)
        }
        .inspector(isPresented: $showComments) {
            CommentsPane(model: model)
                .inspectorColumnWidth(min: 240, ideal: 340, max: 600)
        }
        .navigationTitle(model.pr.title)
        .navigationSubtitle("\(model.pr.repository.nameWithOwner) #\(model.pr.number)")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await model.load() }
            }
            .keyboardShortcut("r")
            Button("Open on GitHub", systemImage: "safari") {
                openURL(model.pr.url)
            }
            Button("Comments", systemImage: "sidebar.right") {
                showComments.toggle()
            }
            .keyboardShortcut("0", modifiers: [.command, .option])
        }
        .task { await model.load() }
    }
}

// MARK: - File tree

private struct FileTreeView: View {
    @Bindable var model: ReviewModel

    var body: some View {
        List(selection: $model.selectedPath) {
            ForEach(model.tree) { node in
                FileTreeNodeView(node: node, model: model)
            }
        }
        .overlay {
            if case .loaded = model.state, model.tree.isEmpty {
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
        switch model.state {
        case .loading:
            ProgressView()
        case let .failed(message):
            ContentUnavailableView("Couldn't load pull request", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded:
            if let file = model.selectedFile {
                DiffView(file: file, commentedLineIDs: model.commentedLineIDs, scrollRequest: model.scrollRequest)
                    .id(file.id) // fresh scroll position per file
            } else {
                ContentUnavailableView("Select a file", systemImage: "doc.text")
            }
        }
    }
}

private struct DiffView: View {
    let file: FileDiff
    let commentedLineIDs: Set<Int>
    let scrollRequest: ReviewModel.ScrollRequest?

    var body: some View {
        if file.isBinary {
            ContentUnavailableView("Binary file", systemImage: "doc.zipper", description: Text(file.path))
        } else if file.hunks.isEmpty {
            ContentUnavailableView("No content changes", systemImage: "doc", description: Text(file.oldPath.map { "Renamed from \($0)" } ?? file.path))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(file.hunks) { hunk in
                            HunkHeaderRow(header: hunk.header)
                            ForEach(hunk.lines) { line in
                                DiffLineRow(line: line, hasComments: commentedLineIDs.contains(line.id))
                                    .id(line.id)
                            }
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                }
                .onChange(of: scrollRequest) { _, request in
                    guard let request else { return }
                    withAnimation { proxy.scrollTo(request.lineID, anchor: .center) }
                }
            }
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
    let hasComments: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            lineNumber(line.oldLine)
            lineNumber(line.newLine)
            Image(systemName: "text.bubble.fill")
                .foregroundStyle(Color.accentColor)
                .opacity(hasComments ? 1 : 0)
                .frame(width: 20)
            Text(marker)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .background(background)
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
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var marker: String {
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
    let model: ReviewModel

    var body: some View {
        let threads = model.selectedThreads
        if threads.isEmpty {
            ContentUnavailableView(
                "No comments",
                systemImage: "bubble.left.and.bubble.right",
                description: Text(model.selectedFile == nil ? "Select a file to see its comments." : "No review comments on this file.")
            )
        } else {
            List(threads) { thread in
                ThreadView(thread: thread)
                    .contentShape(Rectangle())
                    .onTapGesture { model.reveal(thread) }
            }
        }
    }
}

private struct ThreadView: View {
    let thread: ReviewThread

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(location).font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Link(destination: thread.root.htmlUrl) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Open on GitHub")
            }
            ForEach(thread.comments) { comment in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(comment.user).bold()
                        Text("\(comment.createdAt, style: .relative) ago").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Text(markdown(comment.body))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(thread.isOutdated ? 0.6 : 1)
    }

    private var location: String {
        if let line = thread.line { return "Line \(line)" }
        return thread.root.originalLine.map { "Outdated · was line \($0)" } ?? "Outdated"
    }

    private func markdown(_ body: String) -> AttributedString {
        (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(body)
    }
}
