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
        enum Placement { case center, nearest }
        let path: String
        let lineID: Int
        var placement = Placement.center
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

    /// A line comment or reply being written in the comments pane.
    struct InlineDraft {
        enum Target: Equatable {
            case newThread(CommentTarget)
            case reply(threadID: String, to: String)
        }
        var target: Target
        var body = ""
        var error: String?
        var isPosting = false

        var title: String {
            switch target {
            case let .newThread(target): "Comment on \(target.description)"
            case let .reply(_, author): "Reply to \(author)"
            }
        }
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
    var focusedThreadID: String? {
        didSet {
            guard focusedThreadID != oldValue, let id = focusedThreadID,
                let thread = selectedThreads.first(where: { $0.id == id })
            else { return }
            reveal(thread)
        }
    }

    // Line cursor (vim-style) in the selected file's diff
    private(set) var cursorLineID: Int?
    /// Where a `V` range selection started.
    private(set) var selectionAnchor: Int?
    /// Programmatic cursor moves scroll the diff; don't let the resulting visibility changes move the cursor again.
    private var holdCursorUntil = Date.distantPast

    // Writing a review
    var inlineDraft: InlineDraft?
    /// Set to ask the comments pane to focus the draft; it clears this once it has.
    var inlineComposerFocusRequest = false
    private(set) var reviewContext: ReviewContext?
    var isFinishingReview = false
    var reviewSummary = ""
    var reviewEvent = ReviewEvent.comment
    private(set) var reviewError: String?
    private(set) var isSubmittingReview = false

    init(pr: PullRequest) {
        self.pr = pr
    }

    var selectedFile: FileDiff? { selectedPath.flatMap { filesByPath[$0] } }
    var selectedThreads: [ReviewThread] { selectedPath.flatMap { threadsByPath[$0] } ?? [] }

    func file(at path: String) -> FileDiff? { filesByPath[path] }
    func commentCount(at path: String) -> Int {
        threadsByPath[path]?.reduce(0) { $0 + $1.comments.count } ?? 0
    }

    var pendingCommentCount: Int {
        threadsByPath.values.joined().reduce(0) { $0 + $1.comments.count(where: \.isPending) }
    }

    /// IDs of diff lines in the selected file with a current thread, and whether any of those has a draft comment.
    var lineMarkers: [Int: Bool] {
        guard let file = selectedFile else { return [:] }
        var markers: [Int: Bool] = [:]
        for thread in selectedThreads {
            guard let line = thread.line, let id = file.lineID(side: thread.side, line: line) else { continue }
            markers[id] = (markers[id] ?? false) || thread.hasPendingComments
        }
        return markers
    }

    /// Lines covered by the `V` selection, or by the draft comment being written in this file.
    var highlightedLineIDs: ClosedRange<Int>? {
        if let selectionAnchor, let cursorLineID, let file = selectedFile {
            return file.selectionRange(anchor: selectionAnchor, cursor: cursorLineID)
        }
        if case let .newThread(target) = inlineDraft?.target, target.path == selectedPath {
            return target.lineIDs
        }
        return nil
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
            async let threads = cli.reviewThreads(for: pr)
            async let context = cli.reviewContext(for: pr)
            let (files, allThreads, reviewContext) = try await (diffs, threads, context)

            filesByPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            tree = FileTree.build(paths: files.map(\.path))
            filePaths = FileTree.filePaths(in: tree)
            threadsByPath = Dictionary(grouping: allThreads, by: \.path)
            self.reviewContext = reviewContext
            if selectedPath.map({ filesByPath[$0] == nil }) ?? true {
                selectedPath = filePaths.first
                resetCursor()
            } else if let cursorLineID, !(selectedFile?.commentableLines.contains { $0.id == cursorLineID } ?? false) {
                resetCursor()  // the diff changed under the cursor
            }
            filesState = .loaded
        } catch {
            filesState = .failed(error.localizedDescription)
        }
    }

    /// Reloads just the review threads and pending review, after writing to them.
    private func reloadThreads() async {
        guard let cli = try? GitHubCLI() else { return }
        async let threads = cli.reviewThreads(for: pr)
        async let context = cli.reviewContext(for: pr)
        if let threads = try? await threads {
            threadsByPath = Dictionary(grouping: threads, by: \.path)
        }
        if let context = try? await context {
            reviewContext = context
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
        case .cursorDown: return inFiles { moveCursor(by: 1) }
        case .cursorUp: return inFiles { moveCursor(by: -1) }
        case .nextHunk: return inFiles { moveToHunk(offset: 1) }
        case .previousHunk: return inFiles { moveToHunk(offset: -1) }
        case .selectLines: return inFiles { toggleSelection() }
        case .cancel: return cancel()
        case .comment:
            if tab == .files {
                return startComment()
            }
            composerFocusRequest = true
        case .reply: return inFiles { startReply() }
        case .submitReview: isFinishingReview = true
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

    /// Runs a Files-tab action; returns false elsewhere so the key falls through.
    private func inFiles(_ action: () -> Bool) -> Bool {
        tab == .files && selectedFile != nil && action()
    }

    // MARK: Commenting on the conversation

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

    // MARK: Line comments and replies

    /// Opens a draft comment on the cursor line or `V` selection.
    @discardableResult
    func startComment() -> Bool {
        guard let file = selectedFile, let cursorLineID,
            let target = file.commentTarget(anchor: selectionAnchor, cursor: cursorLineID)
        else { return false }
        openDraft(.newThread(target))
        selectionAnchor = nil
        return true
    }

    /// Opens a draft reply to the focused thread, or else a thread on the cursor line.
    @discardableResult
    func startReply(to thread: ReviewThread? = nil) -> Bool {
        let thread =
            thread
            ?? selectedThreads.first { $0.id == focusedThreadID }
            ?? selectedThreads.first { thread in
                thread.line.flatMap { selectedFile?.lineID(side: thread.side, line: $0) } == cursorLineID
            }
        guard let thread else { return false }
        focusedThreadID = thread.id
        openDraft(.reply(threadID: thread.id, to: thread.root.author))
        return true
    }

    private func openDraft(_ target: InlineDraft.Target) {
        // Keep anything already typed; just point it at the new target.
        if var draft = inlineDraft, !draft.body.isEmpty {
            draft.target = target
            draft.error = nil
            inlineDraft = draft
        } else {
            inlineDraft = InlineDraft(target: target)
        }
        showComments = true
        inlineComposerFocusRequest = true
    }

    func discardInlineDraft() {
        inlineDraft = nil
    }

    /// Adds the draft to the pending review (starting one if needed), or posts the reply.
    func postInlineDraft() async {
        guard var draft = inlineDraft, !draft.isPosting else { return }
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft.isPosting = true
        draft.error = nil
        inlineDraft = draft

        do {
            let cli = try GitHubCLI()
            switch draft.target {
            case let .newThread(target):
                let reviewID = try await pendingReviewID(cli)
                try await cli.addReviewThread(on: pr, reviewID: reviewID, target: target, body: body)
            case let .reply(threadID, _):
                try await cli.reply(on: pr, toThread: threadID, body: body)
            }
            inlineDraft = nil
        } catch {
            inlineDraft?.isPosting = false
            inlineDraft?.error = error.localizedDescription
            reviewContext = try? await GitHubCLI().reviewContext(for: pr)  // in case the pending review changed elsewhere
            return
        }
        await reloadThreads()
    }

    private func pendingReviewID(_ cli: GitHubCLI) async throws -> String {
        let context = try await currentReviewContext(cli)
        if let id = context.pendingReviewID { return id }
        let id = try await cli.startReview(on: pr, pullRequestID: context.pullRequestID)
        reviewContext?.pendingReviewID = id
        return id
    }

    private func currentReviewContext(_ cli: GitHubCLI) async throws -> ReviewContext {
        if let reviewContext { return reviewContext }
        let context = try await cli.reviewContext(for: pr)
        reviewContext = context
        return context
    }

    func deletePendingComment(_ comment: ReviewComment) async {
        do {
            try await GitHubCLI().deleteReviewComment(on: pr, commentID: comment.id)
        } catch {
            reviewError = error.localizedDescription
        }
        await reloadThreads()
    }

    // MARK: Finishing the review

    var hasPendingReview: Bool { reviewContext?.pendingReviewID != nil }

    func submitReview() async {
        guard !isSubmittingReview else { return }
        isSubmittingReview = true
        reviewError = nil
        defer { isSubmittingReview = false }
        do {
            let cli = try GitHubCLI()
            let context = try await currentReviewContext(cli)
            try await cli.submitReview(
                on: pr, context: context, event: reviewEvent,
                body: reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } catch {
            reviewError = error.localizedDescription
            reviewContext = try? await GitHubCLI().reviewContext(for: pr)
            return
        }
        isFinishingReview = false
        reviewSummary = ""
        reviewEvent = .comment
        await load()
        // GitHub can take a few seconds to show submitted comments as posted.
        if pendingCommentCount > 0 {
            try? await Task.sleep(for: .seconds(3))
            await reloadThreads()
        }
    }

    func discardReview() async {
        guard let reviewID = reviewContext?.pendingReviewID else { return }
        do {
            try await GitHubCLI().discardReview(on: pr, reviewID: reviewID)
        } catch {
            reviewError = error.localizedDescription
            return
        }
        isFinishingReview = false
        reviewContext?.pendingReviewID = nil
        threadsByPath = threadsByPath.mapValues { $0.compactMap { $0.removingPendingComments() } }
    }

    // MARK: Line cursor

    /// Moves the cursor to a line, e.g. on click. With `extend`, selects from the current cursor (like shift-click).
    func setCursor(_ lineID: Int, extend: Bool = false) {
        if extend {
            if selectionAnchor == nil { selectionAnchor = cursorLineID }
        } else {
            selectionAnchor = nil
        }
        placeCursor(lineID, placement: .nearest)
    }

    private func placeCursor(_ lineID: Int, placement: ScrollRequest.Placement) {
        guard let path = selectedPath else { return }
        cursorLineID = lineID
        holdCursorUntil = .now + 0.5
        scrollRequest = ScrollRequest(path: path, lineID: lineID, placement: placement)
    }

    private func resetCursor() {
        cursorLineID = selectedFile?.commentableLines.first?.id
        selectionAnchor = nil
    }

    private func moveCursor(by offset: Int) -> Bool {
        guard let lines = selectedFile?.commentableLines, !lines.isEmpty else { return false }
        let current = cursorLineID.flatMap { id in lines.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + offset, 0), lines.count - 1) } ?? 0
        placeCursor(lines[next].id, placement: .nearest)
        return true
    }

    private func moveToHunk(offset: Int) -> Bool {
        guard let file = selectedFile else { return false }
        let starts = file.hunks.compactMap { $0.lines.first { $0.commentSide != nil }?.id }
        guard !starts.isEmpty else { return false }
        let cursor = cursorLineID ?? -1
        let target =
            offset > 0
            ? starts.first { $0 > cursor } ?? starts.last!
            : starts.last { $0 < (file.hunk(containing: cursor)?.lines.first?.id ?? cursor) } ?? starts.first!
        placeCursor(target, placement: .center)
        return true
    }

    private func toggleSelection() -> Bool {
        guard cursorLineID != nil else { return false }
        selectionAnchor = selectionAnchor == nil ? cursorLineID : nil
        return true
    }

    /// Esc (when not typing): drops a `V` selection, then an empty draft. False if there was nothing to cancel.
    private func cancel() -> Bool {
        if selectionAnchor != nil {
            selectionAnchor = nil
            return true
        }
        if let draft = inlineDraft, draft.body.isEmpty, !draft.isPosting {
            inlineDraft = nil
            return true
        }
        return false
    }

    /// After scrolling (keys or mouse), keeps the cursor on screen as vim does.
    func diffVisibilityChanged(_ visibleIDs: [Int]) {
        guard Date.now > holdCursorUntil, let file = selectedFile, let cursorLineID else { return }
        let commentable = Set(file.commentableLines.map(\.id))
        let visible = visibleIDs.filter(commentable.contains).sorted()
        guard let first = visible.first, let last = visible.last, !visible.contains(cursorLineID) else { return }
        self.cursorLineID = cursorLineID < first ? first : last
    }

    // MARK: Scrolling

    /// Whether scroll commands apply (they scroll the diff, so only on the Files tab).
    var canScrollDiff: Bool { tab == .files && selectedFile != nil }

    /// Returns false outside the Files tab so the key falls through (e.g. space pages the Overview's web view).
    private func scrollDiff(_ motion: DiffScroll.Motion) -> Bool {
        guard canScrollDiff, let lines = selectedFile?.commentableLines else { return false }
        switch motion {
        case .top: if let first = lines.first { placeCursor(first.id, placement: .nearest) }
        case .bottom: if let last = lines.last { placeCursor(last.id, placement: .nearest) }
        default: break
        }
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
            resetCursor()
        }
        collapsedDirectories = collapsedDirectories.filter { !path.hasPrefix($0 + "/") }
    }

    func selectAdjacentFile(offset: Int) {
        guard !filePaths.isEmpty else { return }
        let next: Int =
            if let current = selectedPath.flatMap(filePaths.firstIndex(of:)) {
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
            next =
                offset > 0
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

    /// Scrolls the diff to the line a thread is anchored to and puts the cursor there (no-op for outdated threads).
    func reveal(_ thread: ReviewThread) {
        guard let file = filesByPath[thread.path], let line = thread.line,
            let id = file.lineID(side: thread.side, line: line)
        else { return }
        selectionAnchor = nil
        placeCursor(id, placement: .center)
    }
}
