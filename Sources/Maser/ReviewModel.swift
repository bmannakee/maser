import AppKit
import MaserCore
import Observation

/// State for one PR review window.
@MainActor @Observable
final class ReviewModel {
    enum LoadState {
        case loading
        case loaded
        case failed(String)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case overview, files

        var id: Self { self }
        var title: String {
            switch self {
            case .overview: "Overview"
            case .files: "Files"
            }
        }
        var command: CommandID {
            switch self {
            case .overview: .showOverview
            case .files: .showFiles
            }
        }
    }

    /// A request to scroll the diff to a line; the token makes repeat requests for the same line distinct.
    struct ScrollRequest: Equatable {
        let path: String
        let lineID: Int
        let token = UUID()
    }

    /// A request to scroll the diff by some amount; the token makes repeat presses distinct.
    struct DiffScroll: Equatable {
        enum Motion: Equatable {
            case lines(Int), halfPages(Int), pages(Int), top, bottom
        }
        let motion: Motion
        let token = UUID()
    }

    let pr: PullRequest
    var tab: Tab = .overview
    var showComments = true

    // Overview
    private(set) var overviewState: LoadState = .loading
    private(set) var overview: PullRequestOverview?
    /// Rendered once per load so the web view doesn't reload (and lose its scroll position) on every view update.
    private(set) var conversationHTML = ""

    // Commenting on the conversation
    var commentDraft = ""
    private(set) var isPostingComment = false
    private(set) var commentError: String?
    /// Set to ask the Overview to focus the comment box; it clears this once it has.
    var composerFocusRequest = false
    /// Changes after a comment is posted, telling the conversation to scroll to it.
    private(set) var conversationScrollToEnd: UUID?

    // Files
    private(set) var filesState: LoadState = .loading
    private(set) var tree: [FileNode] = []
    private var filePaths: [String] = []
    private var filesByPath: [String: FileDiff] = [:]
    private var threadsByPath: [String: [ReviewThread]] = [:]

    var selectedPath: String?
    var collapsedDirectories: Set<String> = []
    var scrollRequest: ScrollRequest?
    var diffScroll: DiffScroll?
    /// The comment thread selected in the comments pane; selecting one scrolls the diff to it.
    var focusedThreadID: Int? {
        didSet {
            guard focusedThreadID != oldValue, let id = focusedThreadID,
                  let thread = selectedThreads.first(where: { $0.id == id })
            else { return }
            reveal(thread)
        }
    }

    init(pr: PullRequest) {
        self.pr = pr
    }

    var selectedFile: FileDiff? { selectedPath.flatMap { filesByPath[$0] } }
    var selectedThreads: [ReviewThread] { selectedPath.flatMap { threadsByPath[$0] } ?? [] }

    func file(at path: String) -> FileDiff? { filesByPath[path] }
    func commentCount(at path: String) -> Int {
        threadsByPath[path]?.reduce(0) { $0 + $1.comments.count } ?? 0
    }

    /// IDs of diff lines in the selected file that have a (current) thread anchored to them.
    var commentedLineIDs: Set<Int> {
        guard let file = selectedFile else { return [] }
        return Set(selectedThreads.compactMap { thread in
            thread.line.flatMap { file.lineID(side: thread.side, line: $0) }
        })
    }

    // MARK: Loading

    func load() async {
        async let overview: Void = loadOverview()
        async let files: Void = loadFiles()
        _ = await (overview, files)
    }

    private func loadOverview() async {
        if overview == nil { overviewState = .loading }
        do {
            let overview = try await GitHubCLI().overview(for: pr)
            self.overview = overview
            conversationHTML = ConversationHTML.render(overview)
            overviewState = .loaded
        } catch {
            overviewState = .failed(error.localizedDescription)
        }
    }

    private func loadFiles() async {
        if filesByPath.isEmpty { filesState = .loading }
        do {
            let cli = try GitHubCLI()
            async let diffs = cli.fileDiffs(for: pr)
            async let comments = cli.reviewComments(for: pr)
            let (files, allComments) = try await (diffs, comments)

            filesByPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            tree = FileTree.build(paths: files.map(\.path))
            filePaths = FileTree.filePaths(in: tree)
            threadsByPath = Dictionary(grouping: ReviewThread.group(allComments), by: \.path)
            if selectedPath.map({ filesByPath[$0] == nil }) ?? true {
                selectedPath = filePaths.first
            }
            filesState = .loaded
        } catch {
            filesState = .failed(error.localizedDescription)
        }
    }

    // MARK: Commands

    /// Runs a window-level command (from the menu bar or a vim-style key). Returns false if it doesn't apply here.
    @discardableResult
    func perform(_ command: CommandID) -> Bool {
        switch command {
        case .showOverview: tab = .overview
        case .showFiles: tab = .files
        case .toggleComments:
            if tab != .files {
                tab = .files
                showComments = true
            } else {
                showComments.toggle()
            }
        case .refresh: Task { await load() }
        case .openOnGitHub: NSWorkspace.shared.open(pr.url)
        case .nextFile: selectAdjacentFile(offset: 1)
        case .previousFile: selectAdjacentFile(offset: -1)
        case .nextThread: focusAdjacentThread(offset: 1)
        case .previousThread: focusAdjacentThread(offset: -1)
        case .comment:
            tab = .overview
            composerFocusRequest = true
        case .scrollDown: return scrollDiff(.lines(1))
        case .scrollUp: return scrollDiff(.lines(-1))
        case .halfPageDown: return scrollDiff(.halfPages(1))
        case .halfPageUp: return scrollDiff(.halfPages(-1))
        case .pageDown: return scrollDiff(.pages(1))
        case .pageUp: return scrollDiff(.pages(-1))
        case .scrollToTop: return scrollDiff(.top)
        case .scrollToBottom: return scrollDiff(.bottom)
        case .openPullRequest, .openConfig, .showKeybindings: return false
        }
        return true
    }

    // MARK: Commenting

    /// Posts the draft to the PR's conversation, then reloads it and scrolls to the new comment.
    /// On failure the draft is kept and the error shown.
    func postComment() async {
        let body = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !isPostingComment else { return }
        isPostingComment = true
        commentError = nil
        defer { isPostingComment = false }
        do {
            try await GitHubCLI().addComment(to: pr, body: body)
        } catch {
            commentError = error.localizedDescription
            return
        }
        commentDraft = ""
        await loadOverview()
        conversationScrollToEnd = UUID()
    }

    /// Appends a Markdown quote of a conversation item ("description" or a comment/review ID) to the draft.
    func quoteReply(to itemID: String) {
        guard let overview else { return }
        let source = itemID == "description" ? overview.body : overview.timeline.first { $0.id == itemID }?.body
        guard let source, !source.isEmpty else { return }
        commentDraft = Markdown.appendingQuote(of: source, to: commentDraft)
        tab = .overview
        composerFocusRequest = true
    }

    /// Whether scroll commands apply (they scroll the diff, so only on the Files tab).
    var canScrollDiff: Bool { tab == .files && selectedFile != nil }

    /// Returns false outside the Files tab so the key falls through (e.g. space pages the Overview's web view).
    private func scrollDiff(_ motion: DiffScroll.Motion) -> Bool {
        guard canScrollDiff else { return false }
        diffScroll = DiffScroll(motion: motion)
        return true
    }

    // MARK: Navigation

    /// Selects a file, expanding any collapsed directories containing it.
    func select(path: String) {
        tab = .files
        if selectedPath != path {
            selectedPath = path
            focusedThreadID = nil
        }
        collapsedDirectories = collapsedDirectories.filter { !path.hasPrefix($0 + "/") }
    }

    func selectAdjacentFile(offset: Int) {
        guard !filePaths.isEmpty else { return }
        let next: Int = if let current = selectedPath.flatMap(filePaths.firstIndex(of:)) {
            min(max(current + offset, 0), filePaths.count - 1)
        } else {
            offset > 0 ? 0 : filePaths.count - 1
        }
        select(path: filePaths[next])
    }

    /// Moves to the next/previous current (non-outdated) comment thread, across files.
    func focusAdjacentThread(offset: Int) {
        let threads = filePaths.flatMap { threadsByPath[$0]?.filter { !$0.isOutdated } ?? [] }
        guard !threads.isEmpty else { return }

        let next: Int
        if let id = focusedThreadID, let current = threads.firstIndex(where: { $0.id == id }) {
            next = min(max(current + offset, 0), threads.count - 1)
        } else {
            // Start from the selected file: its first thread, or the nearest file in that direction.
            let fileIndex = selectedPath.flatMap(filePaths.firstIndex(of:)) ?? -1
            let position = { (thread: ReviewThread) in self.filePaths.firstIndex(of: thread.path) ?? 0 }
            next = offset > 0
                ? threads.firstIndex { position($0) >= fileIndex } ?? 0
                : threads.lastIndex { position($0) <= fileIndex } ?? threads.count - 1
        }

        let thread = threads[next]
        select(path: thread.path)
        showComments = true
        if focusedThreadID == thread.id {
            reveal(thread)
        } else {
            focusedThreadID = thread.id
        }
    }

    /// Scrolls the diff to the line a thread is anchored to (no-op for outdated threads).
    func reveal(_ thread: ReviewThread) {
        guard let file = filesByPath[thread.path], let line = thread.line,
              let id = file.lineID(side: thread.side, line: line)
        else { return }
        scrollRequest = ScrollRequest(path: file.path, lineID: id)
    }
}
