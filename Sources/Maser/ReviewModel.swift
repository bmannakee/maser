// The state and actions behind one pull request review window.
//
// `ReviewModel` loads the PR's overview, changed files, review threads and pending review through `GitHubCLI`, and owns
// everything the window's views share: the current tab, the selected file, the vim-style line cursor and `V` selection,
// comment drafts, and scroll requests. Window commands (menu items and vim-style keys) arrive through `perform(_:)`.

import AppKit
import MaserCore
import Observation

/// State for one PR review window.
@MainActor @Observable
final class ReviewModel {
    /// The progress of loading one part of the window's data.
    enum LoadState {
        /// The first load is in progress; refreshes keep the previous state.
        case loading
        /// The data has loaded.
        case loaded
        /// The load failed, with a message to show the user.
        case failed(String)
    }

    /// One of the review window's whole-window views.
    enum Tab: String, CaseIterable, Identifiable {
        case overview, files

        var id: Self { self }
        /// The tab's name in the toolbar's picker.
        var title: String {
            switch self {
            case .overview: "Overview"
            case .files: "Files"
            }
        }
        /// The command that switches to this tab, for showing its key bindings.
        var command: CommandID {
            switch self {
            case .overview: .showOverview
            case .files: .showFiles
            }
        }
    }

    /// A request to scroll the diff to a line.
    ///
    /// Each request gets a fresh token, so asking for the same line again still counts as a change.
    struct ScrollRequest: Equatable {
        /// Where the line should end up: in the middle of the viewport, or scrolled just far enough to be in view.
        enum Placement { case center, nearest }
        /// The file whose diff should scroll; other files' diffs ignore the request.
        let path: String
        /// The ID of the diff line to scroll to.
        let lineID: Int
        var placement = Placement.center
        let token = UUID()
    }

    /// A request to scroll the diff by some amount.
    ///
    /// Each request gets a fresh token, so repeated key presses all count as changes.
    struct DiffScroll: Equatable {
        /// How far to scroll; counts are negative to scroll up.
        enum Motion: Equatable {
            case lines(Int), halfPages(Int), pages(Int), top, bottom
        }
        let motion: Motion
        let token = UUID()
    }

    /// A line comment or reply being written in the comments pane.
    struct InlineDraft {
        /// What the draft will be posted as.
        enum Target: Equatable {
            /// A new review thread on a line or range of lines.
            case newThread(CommentTarget)
            /// A reply to an existing thread, with the login of the thread's first commenter.
            case reply(threadID: String, to: String)
        }
        var target: Target
        /// The draft's Markdown source.
        var body = ""
        /// The message from the last failed attempt to post the draft.
        var error: String?
        var isPosting = false

        /// The composer's heading, such as "Comment on line 12" or "Reply to octocat".
        var title: String {
            switch target {
            case let .newThread(target): "Comment on \(target.description)"
            case let .reply(_, author): "Reply to \(author)"
            }
        }
    }

    /// The pull request this window reviews.
    let pr: PullRequest
    var tab: Tab = .overview
    /// Whether the Files tab shows the comments pane.
    var showComments = true

    // Overview
    private(set) var overviewState: LoadState = .loading
    /// The PR's description and conversation, once loaded.
    private(set) var overview: PullRequestOverview?
    /// The conversation as HTML for the Overview's web view.
    ///
    /// It's rendered once per load so the web view doesn't reload, and lose its scroll position, on every view update.
    private(set) var conversationHTML = ""

    // Commenting on the conversation
    /// The Markdown source of the comment being written for the PR's conversation.
    var commentDraft = ""
    private(set) var isPostingComment = false
    /// The message from the last failed attempt to post `commentDraft`.
    private(set) var commentError: String?
    /// Set to ask the Overview to focus the comment box; it clears this once it has.
    var composerFocusRequest = false
    /// A new value after each posted comment, telling the conversation to scroll to the end.
    private(set) var conversationScrollToEnd: UUID?

    // Files
    private(set) var filesState: LoadState = .loading
    /// The changed files as a directory tree, for the file list.
    private(set) var tree: [FileNode] = []
    /// The changed files' paths in the order the tree shows them, for next/previous navigation.
    private var filePaths: [String] = []
    private var filesByPath: [String: FileDiff] = [:]
    /// All review threads, current and outdated, grouped by file path.
    private var threadsByPath: [String: [ReviewThread]] = [:]

    /// The path of the file shown in the Files tab.
    var selectedPath: String?
    /// Paths of the directories collapsed in the file tree; every other directory is expanded.
    var collapsedDirectories: Set<String> = []
    /// The latest request to scroll the diff to a line.
    var scrollRequest: ScrollRequest?
    /// The latest request to scroll the diff by a vim-style motion.
    var diffScroll: DiffScroll?
    /// The comment thread selected in the comments pane.
    ///
    /// Changing it to a thread in the selected file scrolls the diff to the thread's line and moves the cursor there.
    var focusedThreadID: String? {
        didSet {
            guard focusedThreadID != oldValue, let id = focusedThreadID,
                let thread = selectedThreads.first(where: { $0.id == id })
            else { return }
            reveal(thread)
        }
    }

    // Line cursor (vim-style) in the selected file's diff
    /// The ID of the diff line the cursor is on; always a line that can take a comment.
    private(set) var cursorLineID: Int?
    /// The line ID where a `V` range selection started, or nil when nothing is selected.
    private(set) var selectionAnchor: Int?
    /// Until this time, `diffVisibilityChanged(_:)` leaves the cursor alone.
    ///
    /// Programmatic cursor moves scroll the diff, and the visibility changes that causes mustn't move the cursor again.
    private var holdCursorUntil = Date.distantPast

    // Writing a review
    /// The line comment or reply being written, if any.
    var inlineDraft: InlineDraft?
    /// Set to ask the comments pane to focus the draft; it clears this once it has.
    var inlineComposerFocusRequest = false
    /// The PR's node ID and the viewer's pending review, once loaded.
    private(set) var reviewContext: ReviewContext?
    /// Whether the Finish Review sheet is showing.
    var isFinishingReview = false
    /// The Markdown summary to submit with the review.
    var reviewSummary = ""
    /// The verdict to submit the review with.
    var reviewEvent = ReviewEvent.comment
    /// The message from the last failed review action: submitting, discarding, or deleting a draft comment.
    private(set) var reviewError: String?
    private(set) var isSubmittingReview = false

    /// Creates the state for a review window; call `load()` to fetch the PR's data.
    ///
    /// - Parameter pr: The pull request to review.
    init(pr: PullRequest) {
        self.pr = pr
    }

    /// The diff of the selected file, once loaded.
    var selectedFile: FileDiff? { selectedPath.flatMap { filesByPath[$0] } }
    /// All review threads on the selected file, including outdated ones.
    var selectedThreads: [ReviewThread] { selectedPath.flatMap { threadsByPath[$0] } ?? [] }

    /// Returns the diff of a changed file.
    ///
    /// - Parameter path: The file's path in the PR's head.
    /// - Returns: The file's diff, or nil if the path isn't one of the PR's changed files.
    func file(at path: String) -> FileDiff? { filesByPath[path] }
    /// Returns the number of review comments on a file, counting every comment in every thread.
    ///
    /// - Parameter path: The file's path in the PR's head.
    /// - Returns: The comment count, or 0 for a file without threads.
    func commentCount(at path: String) -> Int {
        threadsByPath[path]?.reduce(0) { $0 + $1.comments.count } ?? 0
    }

    /// The number of the viewer's draft comments in the pending review, across all files.
    var pendingCommentCount: Int {
        threadsByPath.values.joined().reduce(0) { $0 + $1.comments.count(where: \.isPending) }
    }

    /// The gutter markers for the selected file's diff.
    ///
    /// Maps the IDs of lines with a current (non-outdated) thread to whether any of those threads has a draft comment.
    var lineMarkers: [Int: Bool] {
        guard let file = selectedFile else { return [:] }
        var markers: [Int: Bool] = [:]
        for thread in selectedThreads {
            guard let line = thread.line, let id = file.lineID(side: thread.side, line: line) else { continue }
            markers[id] = (markers[id] ?? false) || thread.hasPendingComments
        }
        return markers
    }

    /// The line IDs to highlight in the diff.
    ///
    /// That's the `V` selection while there is one, or else the lines a new-thread draft in this file covers.
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

    /// Loads, or refreshes, the overview and the Files tab's data in parallel.
    ///
    /// Failures are reported through `overviewState` and `filesState`. A refresh keeps the selected file when it's
    /// still in the PR.
    func load() async {
        async let overview: Void = loadOverview()
        async let files: Void = loadFiles()
        _ = await (overview, files)
    }

    /// Loads the PR's description and conversation, and renders the conversation's HTML.
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

    /// Loads the changed files' diffs, the review threads and the review context.
    ///
    /// Selects the first file if the selected one is gone, and resets the cursor if its line is gone.
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

    /// Reloads just the review threads and the review context, after writing to them.
    ///
    /// Failures are ignored and keep the current values.
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

    /// Runs a window-level command from the menu bar or a vim-style key.
    ///
    /// - Parameter command: The command to run.
    /// - Returns: False if the command doesn't apply here, so the key can fall through to other handlers.
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
        // App-wide commands, handled for every window by `commandHandler(_:)`.
        case .openPullRequest, .openConfig, .showKeybindings: return false
        }
        return true
    }

    /// Runs an action that needs the Files tab with a file selected.
    ///
    /// - Parameter action: The action; it returns whether it applied.
    /// - Returns: The action's result, or false without running it elsewhere, so the key falls through.
    private func inFiles(_ action: () -> Bool) -> Bool {
        tab == .files && selectedFile != nil && action()
    }

    // MARK: Commenting on the conversation

    /// Posts `commentDraft` to the PR's conversation, then reloads the overview and scrolls to the new comment.
    ///
    /// Does nothing if the draft is blank or a post is already in progress. On failure the draft is kept and
    /// `commentError` is set.
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

    /// Appends a Markdown quote of a conversation item to `commentDraft`, then focuses the comment box.
    ///
    /// Does nothing if the item isn't found or has no text.
    ///
    /// - Parameter itemID: `"description"` for the PR's description, or the ID of a timeline comment or review.
    func quoteReply(to itemID: String) {
        guard let overview else { return }
        let source = itemID == "description" ? overview.body : overview.timeline.first { $0.id == itemID }?.body
        guard let source, !source.isEmpty else { return }
        commentDraft = Markdown.appendingQuote(of: source, to: commentDraft)
        tab = .overview
        composerFocusRequest = true
    }

    // MARK: Line comments and replies

    /// Opens a draft comment on the cursor line or the `V` selection, and ends the selection.
    ///
    /// - Returns: False if there's no cursor line to comment on.
    @discardableResult
    func startComment() -> Bool {
        guard let file = selectedFile, let cursorLineID,
            let target = file.commentTarget(anchor: selectionAnchor, cursor: cursorLineID)
        else { return false }
        openDraft(.newThread(target))
        selectionAnchor = nil
        return true
    }

    /// Opens a draft reply to a thread and focuses that thread.
    ///
    /// - Parameter thread: The thread to reply to. If nil, replies to the focused thread, or else to a thread on the
    ///   cursor line.
    /// - Returns: False if there's no thread to reply to.
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

    /// Shows the comments pane with a draft for a target, and asks the pane to focus it.
    ///
    /// Text already typed in the current draft is kept and retargeted.
    ///
    /// - Parameter target: What the draft will be posted as.
    private func openDraft(_ target: InlineDraft.Target) {
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

    /// Throws away the line comment or reply being written.
    func discardInlineDraft() {
        inlineDraft = nil
    }

    /// Posts the inline draft, then reloads the threads.
    ///
    /// A new thread goes into the viewer's pending review, starting one if needed. A reply joins the pending review if
    /// there is one and is posted right away otherwise. Does nothing if the draft is blank or already posting. On
    /// failure the draft is kept with its `error` set.
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

    /// Returns the ID of the viewer's pending review, starting one if they don't have one.
    ///
    /// - Parameter cli: The client to make requests with.
    /// - Returns: The pending review's node ID.
    /// - Throws: `GitHubCLIError` if fetching the review context or starting the review fails.
    private func pendingReviewID(_ cli: GitHubCLI) async throws -> String {
        let context = try await currentReviewContext(cli)
        if let id = context.pendingReviewID { return id }
        let id = try await cli.startReview(on: pr, pullRequestID: context.pullRequestID)
        reviewContext?.pendingReviewID = id
        return id
    }

    /// Returns the loaded review context, fetching and storing it if there isn't one yet.
    ///
    /// - Parameter cli: The client to fetch the context with.
    /// - Returns: The PR's node ID and the viewer's pending review.
    /// - Throws: `GitHubCLIError` if fetching the context fails.
    private func currentReviewContext(_ cli: GitHubCLI) async throws -> ReviewContext {
        if let reviewContext { return reviewContext }
        let context = try await cli.reviewContext(for: pr)
        reviewContext = context
        return context
    }

    /// Deletes one of the viewer's draft comments, then reloads the threads.
    ///
    /// On failure, sets `reviewError`.
    ///
    /// - Parameter comment: The draft comment to delete.
    func deletePendingComment(_ comment: ReviewComment) async {
        do {
            try await GitHubCLI().deleteReviewComment(on: pr, commentID: comment.id)
        } catch {
            reviewError = error.localizedDescription
        }
        await reloadThreads()
    }

    // MARK: Finishing the review

    /// Whether the viewer has a pending review on this PR, as of the last load.
    var hasPendingReview: Bool { reviewContext?.pendingReviewID != nil }

    /// Submits the review with `reviewSummary` and `reviewEvent`, then closes the sheet and reloads everything.
    ///
    /// Without a pending review this posts a review with just the summary and verdict. Does nothing while a submit is
    /// already in progress. On failure the sheet stays open with `reviewError` set.
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

    /// Deletes the viewer's pending review and its draft comments, then closes the sheet.
    ///
    /// Does nothing without a pending review. On failure, sets `reviewError`.
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
        // GitHub takes a few seconds to reflect the deletion, so drop the drafts locally instead of reloading.
        threadsByPath = threadsByPath.mapValues { $0.compactMap { $0.removingPendingComments() } }
    }

    // MARK: Line cursor

    /// Moves the cursor to a line, for example on a click, and scrolls just enough to show it.
    ///
    /// - Parameters:
    ///   - lineID: The ID of the line to move to.
    ///   - extend: Whether to select from the current cursor line, like shift-click. Otherwise any selection ends.
    func setCursor(_ lineID: Int, extend: Bool = false) {
        if extend {
            if selectionAnchor == nil { selectionAnchor = cursorLineID }
        } else {
            selectionAnchor = nil
        }
        placeCursor(lineID, placement: .nearest)
    }

    /// Moves the cursor to a line in the selected file and scrolls the diff to it.
    ///
    /// - Parameters:
    ///   - lineID: The ID of the line to move to.
    ///   - placement: Where the line should end up in the viewport.
    private func placeCursor(_ lineID: Int, placement: ScrollRequest.Placement) {
        guard let path = selectedPath else { return }
        cursorLineID = lineID
        holdCursorUntil = .now + 0.5
        scrollRequest = ScrollRequest(path: path, lineID: lineID, placement: placement)
    }

    /// Puts the cursor on the selected file's first commentable line and ends any selection.
    private func resetCursor() {
        cursorLineID = selectedFile?.commentableLines.first?.id
        selectionAnchor = nil
    }

    /// Moves the cursor by some number of commentable lines, stopping at the first and last.
    ///
    /// - Parameter offset: How many lines to move; negative moves up.
    /// - Returns: False if the file has no commentable lines.
    private func moveCursor(by offset: Int) -> Bool {
        guard let lines = selectedFile?.commentableLines, !lines.isEmpty else { return false }
        let current = cursorLineID.flatMap { id in lines.firstIndex { $0.id == id } }
        let next = current.map { min(max($0 + offset, 0), lines.count - 1) } ?? 0
        placeCursor(lines[next].id, placement: .nearest)
        return true
    }

    /// Moves the cursor to the first line of the next or previous hunk, and centers it.
    ///
    /// Stays on the last or first hunk at either end. Moving back from inside a hunk goes to the previous hunk, not the
    /// start of the current one.
    ///
    /// - Parameter offset: Positive for the next hunk, otherwise the previous one.
    /// - Returns: False if the file has no commentable lines.
    private func moveToHunk(offset: Int) -> Bool {
        guard let file = selectedFile else { return false }
        let starts = file.hunks.compactMap { $0.lines.first { $0.commentSide != nil }?.id }
        guard !starts.isEmpty else { return false }
        let cursor = cursorLineID ?? -1
        // `starts` isn't empty (checked above), so `last!` and `first!` can't fail.
        let target =
            offset > 0
            ? starts.first { $0 > cursor } ?? starts.last!
            : starts.last { $0 < (file.hunk(containing: cursor)?.lines.first?.id ?? cursor) } ?? starts.first!
        placeCursor(target, placement: .center)
        return true
    }

    /// Starts a `V` range selection at the cursor, or ends the current one.
    ///
    /// - Returns: False if there's no cursor.
    private func toggleSelection() -> Bool {
        guard cursorLineID != nil else { return false }
        selectionAnchor = selectionAnchor == nil ? cursorLineID : nil
        return true
    }

    /// Handles Esc when not typing: ends a `V` selection, or else closes an empty inline draft.
    ///
    /// - Returns: False if there was nothing to cancel.
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

    /// Keeps the cursor on screen after the diff scrolls, as vim does, by moving it to the nearest visible line.
    ///
    /// Ignored shortly after a programmatic cursor move, whose own scrolling would otherwise move the cursor again.
    ///
    /// - Parameter visibleIDs: The IDs of the diff lines now on screen.
    func diffVisibilityChanged(_ visibleIDs: [Int]) {
        guard Date.now > holdCursorUntil, let file = selectedFile, let cursorLineID else { return }
        let commentable = Set(file.commentableLines.map(\.id))
        let visible = visibleIDs.filter(commentable.contains).sorted()
        guard let first = visible.first, let last = visible.last, !visible.contains(cursorLineID) else { return }
        self.cursorLineID = cursorLineID < first ? first : last
    }

    // MARK: Scrolling

    /// Whether scroll commands apply: they scroll the diff, so only on the Files tab with a file selected.
    var canScrollDiff: Bool { tab == .files && selectedFile != nil }

    /// Asks the diff to scroll by a vim-style motion; scrolling to the top or bottom also moves the cursor there.
    ///
    /// - Parameter motion: How far to scroll.
    /// - Returns: False outside the Files tab, so the key falls through (for example, space pages the Overview).
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

    /// Shows a file in the Files tab, expanding any collapsed directories that contain it.
    ///
    /// Switching to a different file clears the focused thread and puts the cursor on its first line.
    ///
    /// - Parameter path: The file's path in the PR's head.
    func select(path: String) {
        tab = .files
        if selectedPath != path {
            selectedPath = path
            focusedThreadID = nil
            resetCursor()
        }
        collapsedDirectories = collapsedDirectories.filter { !path.hasPrefix($0 + "/") }
    }

    /// Selects a file before or after the selected one, in file-tree order, stopping at the first and last.
    ///
    /// - Parameter offset: How many files to move; negative moves up. With no file selected, moving down picks the
    ///   first file and moving up the last.
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

    /// Focuses a current (non-outdated) comment thread before or after the focused one, across files.
    ///
    /// Selects the thread's file, shows the comments pane, and scrolls the diff to the thread. Stops at the first and
    /// last threads. With no focused thread, starts from the selected file.
    ///
    /// - Parameter offset: How many threads to move; negative moves back.
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
        // Setting `focusedThreadID` reveals the thread, but not when it's unchanged.
        if focusedThreadID == thread.id {
            reveal(thread)
        } else {
            focusedThreadID = thread.id
        }
    }

    /// Scrolls the diff to the line a thread is anchored to, centered, and moves the cursor there.
    ///
    /// Does nothing for an outdated thread, which has no line in the current diff.
    ///
    /// - Parameter thread: The thread to show.
    func reveal(_ thread: ReviewThread) {
        guard let file = filesByPath[thread.path], let line = thread.line,
            let id = file.lineID(side: thread.side, line: line)
        else { return }
        selectionAnchor = nil
        placeCursor(id, placement: .center)
    }
}
