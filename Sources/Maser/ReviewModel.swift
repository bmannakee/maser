// The state and actions behind one pull request's review.
//
// `ReviewModel` loads the PR's overview, changed files, review threads and pending review through `GitHubCLI`, and owns
// everything the review's views share: the current tab, the selected file and whether it shows in full, the vim-style
// line cursor and `V` selection, comment drafts, and scroll requests. Commands (menu items and vim-style keys) arrive
// through `perform(_:)`. The main window keeps one per PR it has shown, so going back to a PR keeps its state.

import AppKit
import MaserCore
import Observation

/// State for one PR's review, in the main window or a window of its own.
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
        case overview, files, agent

        var id: Self { self }
        /// The tab's name in the toolbar's picker.
        var title: String {
            switch self {
            case .overview: "Overview"
            case .files: "Files"
            case .agent: "Agent"
            }
        }
        /// The command that switches to this tab, for showing its key bindings.
        var command: CommandID {
            switch self {
            case .overview: .showOverview
            case .files: .showFiles
            case .agent: .showAgent
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
        typealias Target = DraftTarget
        var target: Target
        /// The head commit of the diff the target was chosen on; a new thread is only posted while it's still the head.
        var commitID: String?
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

        /// The part of the draft kept across crashes and quits; nil while it has no text.
        var unsent: UnsentText.LineComment? {
            body.isEmpty ? nil : UnsentText.LineComment(target: target, commitID: commitID, body: body)
        }
    }

    /// Where every review keeps its unsent text: a folder in Application Support named for the app's bundle, so the
    /// UI scenarios' build keeps its own.
    static let unsentStore = UnsentTextStore(
        directory: URL.applicationSupportDirectory.appending(path: Bundle.main.bundleIdentifier ?? "dev.maser.Maser")
            .appending(path: "Unsent"))

    /// The pull request this window reviews.
    let pr: PullRequest
    /// The conversation with the review agent about this PR.
    let agent: AgentSession
    var tab: Tab = .overview
    /// Whether the Files tab shows the comments pane.
    var showComments = true

    // Overview
    private(set) var overviewState: LoadState = .loading
    /// The PR's description and conversation, once loaded.
    private(set) var overview: PullRequestOverview?
    /// The conversation as HTML for the Overview's web view.
    ///
    /// It's rendered once per load, and again when `refreshConversationTimes()` finds its relative times out of date,
    /// so the web view doesn't reload on every view update.
    private(set) var conversationHTML = ""

    // Commenting on the conversation
    /// The Markdown source of the comment being written for the PR's conversation.
    var commentDraft = "" {
        didSet {
            if commentDraft != oldValue { saveUnsent { $0.comment = self.commentDraft } }
        }
    }
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

    // Whole-file view
    /// Whether files show in full unless toggled one by one; starts from the config's `[diff] view`.
    private(set) var showsFullFiles: Bool
    /// Files toggled away from `showsFullFiles`, by path: true to show in full, false for just the hunks.
    private var fullFileOverrides: [String: Bool] = [:]
    /// Whole-file versions of the changed files, by path, built for the current diff.
    private var fullFiles: [String: FileDiff] = [:]
    /// File contents fetched from GitHub, keyed by `"commit:path"`, kept across refreshes.
    private var headTexts: [String: String] = [:]
    /// Paths whose contents are being fetched.
    private(set) var loadingFullFiles: Set<String> = []
    /// Why a file couldn't be shown in full, by path.
    private(set) var fullFileErrors: [String: String] = [:]
    /// A short note about the last key that couldn't do anything, shown under the diff until the cursor moves.
    private(set) var diffNotice: String?

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
    /// When `load()` last finished, for `loadIfStale(maxAge:)`.
    private var loadedAt: Date?

    // Writing a review
    /// The line comment or reply being written, if any.
    var inlineDraft: InlineDraft? {
        didSet {
            let unsent = inlineDraft?.unsent
            if unsent != oldValue?.unsent { saveUnsent { $0.lineComment = unsent } }
        }
    }
    /// Set to ask the comments pane to focus the draft; it clears this once it has.
    var inlineComposerFocusRequest = false
    /// The PR's node ID and the viewer's pending review, once loaded.
    private(set) var reviewContext: ReviewContext?
    /// The head commit the shown diff was loaded at; comments and reviews are posted only while it's still the head.
    private(set) var diffCommitID: String?
    /// The account `gh` will post as, as last fetched; the comment boxes and Finish Review show it.
    var postingAccount: String? { reviewContext?.viewerLogin }
    /// Whether the last submit was stopped because new commits were pushed, so the sheet offers a refresh.
    private(set) var reviewHeadMoved = false
    /// Whether the Finish Review sheet is showing.
    var isFinishingReview = false
    /// The Markdown summary to submit with the review.
    var reviewSummary = "" {
        didSet {
            if reviewSummary != oldValue { saveUnsent { $0.reviewSummary = self.reviewSummary } }
        }
    }
    /// The verdict to submit the review with.
    var reviewEvent = ReviewEvent.comment
    /// The message from the last failed review action: submitting, discarding, or deleting a draft comment.
    private(set) var reviewError: String?
    private(set) var isSubmittingReview = false

    /// Whether the PR left the main window's queue while showing here, kept open because it had unsent text.
    var leftQueue = false

    /// Whether any comment, line comment, reply or summary has text that hasn't been posted.
    var hasUnsentText: Bool {
        !UnsentText(comment: commentDraft, lineComment: inlineDraft?.unsent, reviewSummary: reviewSummary).isEmpty
    }

    /// Creates the state for a PR's review, with any text left unsent last time; call `load()` to fetch the PR's data.
    ///
    /// - Parameter pr: The pull request to review.
    init(pr: PullRequest) {
        self.pr = pr
        agent = AgentSession(pr: pr)
        showsFullFiles = ConfigStore.shared.settings.diffView == .full
        do {
            let unsent = try Self.unsentStore.load(for: pr)
            commentDraft = unsent.comment
            reviewSummary = unsent.reviewSummary
            inlineDraft = unsent.lineComment.map { InlineDraft(target: $0.target, commitID: $0.commitID, body: $0.body) }
        } catch {
            NSLog("Couldn't read the unsent text for %@: %@", pr.url.absoluteString, error.localizedDescription)
        }
        agent.review = self
    }

    /// Saves a change to the PR's unsent text, so it survives a crash or quit.
    ///
    /// Called as the user types. A failure is logged and the text stays in memory.
    ///
    /// - Parameter change: Sets the part of the text that changed.
    private func saveUnsent(_ change: (inout UnsentText) -> Void) {
        do {
            try Self.unsentStore.update(for: pr, change)
        } catch {
            NSLog("Couldn't save the unsent text for %@: %@", pr.url.absoluteString, error.localizedDescription)
        }
    }

    /// The changed files' diffs, in the order the file tree shows them.
    var diffFiles: [FileDiff] { filePaths.compactMap { filesByPath[$0] } }
    /// Every review thread, by file path.
    var allThreads: [ReviewThread] { threadsByPath.keys.sorted().flatMap { threadsByPath[$0] ?? [] } }

    /// The selected file as the Files tab shows it: its hunks, or the whole file.
    var selectedFile: FileDiff? { selectedPath.flatMap(displayedFile(at:)) }
    /// All review threads on the selected file, including outdated ones.
    var selectedThreads: [ReviewThread] { selectedPath.flatMap { threadsByPath[$0] } ?? [] }

    /// Returns the diff of a changed file.
    ///
    /// - Parameter path: The file's path in the PR's head.
    /// - Returns: The file's diff, or nil if the path isn't one of the PR's changed files.
    func file(at path: String) -> FileDiff? { filesByPath[path] }

    /// Returns a changed file as the Files tab shows it.
    ///
    /// - Parameter path: The file's path in the PR's head.
    /// - Returns: The whole file if it's set to show in full and has loaded, otherwise its hunks; nil if the path isn't
    ///   one of the PR's changed files.
    private func displayedFile(at path: String) -> FileDiff? {
        if wantsFullFile(path), let full = fullFiles[path] { return full }
        return filesByPath[path]
    }
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
        if case let .newThread(target) = inlineDraft?.target, target.path == selectedPath, let file = selectedFile {
            return file.lineIDs(for: target)
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
        loadedAt = .now
    }

    /// Loads the PR's data unless it loaded recently, as when going back to a PR in the main window.
    ///
    /// - Parameter maxAge: How many seconds old the data may be before it's refreshed.
    func loadIfStale(maxAge: TimeInterval) async {
        if let loadedAt, Date.now.timeIntervalSince(loadedAt) < maxAge { return }
        await load()
    }

    /// Loads the PR's description and conversation, and renders the conversation's HTML.
    ///
    /// If a refresh fails while an overview is already showing, the last good one stays up.
    private func loadOverview() async {
        if overview == nil { overviewState = .loading }
        do {
            let overview = try await GitHubCLI().overview(for: pr)
            self.overview = overview
            conversationHTML = ConversationHTML.render(overview)
            overviewState = .loaded
        } catch {
            // A transient failure (e.g. on the reload after posting) shouldn't blank the conversation.
            if overview == nil { overviewState = .failed(error.localizedDescription) }
        }
    }

    /// Loads the changed files' diffs, the review threads and the review context.
    ///
    /// Selects the first file if the selected one is gone. Otherwise the cursor stays on the same line, or the nearest
    /// one if the diff changed under it.
    private func loadFiles() async {
        if filesByPath.isEmpty { filesState = .loading }
        do {
            let cli = GitHubCLI()
            async let diff = cli.diffAtHead(for: pr)
            async let threads = cli.reviewThreads(for: pr)
            let ((files, reviewContext), allThreads) = try await (diff, threads)

            preservingCursor {
                filesByPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
                tree = FileTree.build(paths: files.map(\.path))
                filePaths = FileTree.filePaths(in: tree)
                threadsByPath = Dictionary(grouping: allThreads, by: \.path)
                self.reviewContext = reviewContext
                diffCommitID = reviewContext.headCommitID
                if case .newThread = inlineDraft?.target, inlineDraft?.commitID != diffCommitID {
                    inlineDraft?.error = Self.placeAgainMessage
                }
                // The diff may have changed, so rebuild the whole-file views; contents already fetched are reused.
                fullFiles = [:]
                fullFileErrors = [:]
                prepareFullFile()
            }
            if selectedPath.map({ filesByPath[$0] == nil }) ?? true {
                showFile(filePaths.first)
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
        let cli = GitHubCLI()
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
        case .showAgent: tab = .agent
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
        case .toggleFullFile: return inFiles { toggleFullFile() }
        case .expandAllFiles: return inFiles { setAllFilesFull(true) }
        case .collapseAllFiles: return inFiles { setAllFilesFull(false) }
        case .selectLines: return inFiles { toggleSelection() }
        case .cancel: return cancel()
        case .comment:
            if tab == .files {
                return startComment()
            }
            if tab == .agent {
                agent.focusRequest = true
                return true
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
        case .openPullRequest, .openConfig, .showKeybindings, .showPullRequests: return false
        // The main window's queue handles these; Return falls through to whatever has focus.
        case .togglePullRequests, .openSelected: return false
        // Only the review queue has a filter.
        case .filter: return false
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
            let cli = GitHubCLI()
            _ = try await checkedContext(cli)
            try await cli.addComment(to: pr, body: body)
        } catch {
            commentError = error.localizedDescription
            return
        }
        commentDraft = ""
        await loadOverview()
        conversationScrollToEnd = UUID()
    }

    /// Re-renders the conversation if its relative times ("5 minutes ago") have changed since it was rendered.
    ///
    /// The Overview calls this every minute while it's showing.
    func refreshConversationTimes() {
        guard let overview else { return }
        let html = ConversationHTML.render(overview)
        if html != conversationHTML { conversationHTML = html }
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
    /// On a line filled in from the whole file, which GitHub won't take comments on, it explains that in `diffNotice`
    /// instead.
    ///
    /// - Returns: False if there's no cursor line to comment on.
    @discardableResult
    func startComment() -> Bool {
        guard let file = selectedFile, let cursorLineID else { return false }
        guard let target = file.commentTarget(anchor: selectionAnchor, cursor: cursorLineID) else {
            guard file.line(withID: cursorLineID)?.isExpansion == true else { return false }
            diffNotice = "GitHub only takes comments on lines in the diff, not the rest of the file."
            return true
        }
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
    /// Text already typed in the current draft is kept and retargeted. Does nothing while a draft is posting, so the
    /// post's completion can't clobber a new draft.
    ///
    /// - Parameter target: What the draft will be posted as.
    private func openDraft(_ target: InlineDraft.Target) {
        guard inlineDraft?.isPosting != true else { return }
        if var draft = inlineDraft, !draft.body.isEmpty {
            draft.target = target
            draft.commitID = diffCommitID
            draft.error = nil
            inlineDraft = draft
        } else {
            inlineDraft = InlineDraft(target: target, commitID: diffCommitID)
        }
        showComments = true
        inlineComposerFocusRequest = true
    }

    /// What a line comment says when the diff it was placed on has been replaced by a newer one.
    static let placeAgainMessage =
        "The diff changed since this comment was placed. Press c on the line to place it on the new diff; your text is kept."

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
            let cli = GitHubCLI()
            switch draft.target {
            case let .newThread(target):
                // GitHub puts a new thread on the current head, so its line numbers must come from that commit's diff.
                guard let seen = draft.commitID else { throw GitHubCLIError.rejected("The diff hasn't loaded yet.") }
                guard seen == diffCommitID else { throw GitHubCLIError.rejected(Self.placeAgainMessage) }
                let context = try await checkedContext(cli, head: seen)
                let reviewID = try await pendingReviewID(cli, context: context, commitID: seen)
                try await cli.addReviewThread(on: pr, reviewID: reviewID, target: target, body: body)
            case let .reply(threadID, _):
                _ = try await checkedContext(cli)
                try await cli.reply(on: pr, toThread: threadID, body: body)
            }
            inlineDraft = nil
        } catch {
            inlineDraft?.isPosting = false
            inlineDraft?.error = error.localizedDescription
            // The pending review may have changed elsewhere; refresh it, keeping what we had if that fails too.
            if let context = try? await GitHubCLI().reviewContext(for: pr) { reviewContext = context }
            return
        }
        await reloadThreads()
    }

    /// Fetches the review context just before posting, and checks it still matches what the user was shown.
    ///
    /// The fresh context replaces the stored one either way, so after a refusal the views show the current account and
    /// posting again posts as it.
    ///
    /// - Parameters:
    ///   - cli: The client to fetch with.
    ///   - head: The commit the post's diff was loaded at, to check the head against; nil for posts that don't depend
    ///     on line numbers.
    /// - Returns: The fresh context.
    /// - Throws: `GitHubCLIError.accountChanged` if `gh`'s account isn't the one shown, `GitHubCLIError.headMoved` if
    ///   the head moved, or the errors from `reviewContext(for:)`.
    private func checkedContext(_ cli: GitHubCLI, head: String? = nil) async throws -> ReviewContext {
        let shown = postingAccount
        let context = try await cli.reviewContext(for: pr)
        reviewContext = context
        try context.requireViewer(shown)
        if let head { try context.requireHead(head) }
        return context
    }

    /// Returns the ID of the viewer's pending review, starting one pinned to `commitID` if they don't have one.
    ///
    /// - Parameters:
    ///   - cli: The client to make requests with.
    ///   - context: A freshly fetched review context.
    ///   - commitID: The head commit of the diff the user saw.
    /// - Returns: The pending review's node ID.
    /// - Throws: `GitHubCLIError` if starting the review fails.
    private func pendingReviewID(_ cli: GitHubCLI, context: ReviewContext, commitID: String) async throws -> String {
        if let id = context.pendingReviewID { return id }
        let id = try await cli.startReview(on: pr, pullRequestID: context.pullRequestID, commitID: commitID)
        reviewContext?.pendingReviewID = id
        return id
    }

    /// Deletes one of the viewer's draft comments, then reloads the threads.
    ///
    /// On failure, sets `reviewError`.
    ///
    /// - Parameter comment: The draft comment to delete.
    func deletePendingComment(_ comment: ReviewComment) async {
        reviewError = nil
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

    /// Whether submitting needs a summary: GitHub rejects a Comment or Request changes review with no body and no
    /// draft comments.
    var reviewNeedsSummary: Bool {
        reviewEvent != .approve && pendingCommentCount == 0
            && reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Submits the review with `reviewSummary` and `reviewEvent`, then closes the sheet and reloads everything.
    ///
    /// Without a pending review this posts a review with just the summary and verdict. Does nothing while a submit is
    /// already in progress. On failure the sheet stays open with `reviewError` set.
    func submitReview() async {
        guard !isSubmittingReview else { return }
        isSubmittingReview = true
        reviewError = nil
        reviewHeadMoved = false
        defer { isSubmittingReview = false }
        do {
            guard let seen = diffCommitID else { throw GitHubCLIError.rejected("The diff hasn't loaded yet.") }
            let cli = GitHubCLI()
            // Fresh, so a verdict never covers commits pushed after the diff loaded.
            let context = try await checkedContext(cli, head: seen)
            try await cli.submitReview(
                on: pr, context: context, event: reviewEvent,
                body: reviewSummary.trimmingCharacters(in: .whitespacesAndNewlines), commitID: seen
            )
        } catch {
            reviewError = error.localizedDescription
            if case GitHubCLIError.headMoved = error { reviewHeadMoved = true }
            if let context = try? await GitHubCLI().reviewContext(for: pr) { reviewContext = context }
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

    /// Closes the Finish Review sheet and reloads the PR, after a submit stopped because new commits were pushed.
    ///
    /// The summary, verdict and draft comments are kept, so the user can review the new commits and submit again.
    func refreshAfterHeadMoved() async {
        isFinishingReview = false
        reviewError = nil
        reviewHeadMoved = false
        await load()
    }

    /// Deletes the viewer's pending review and its draft comments, then closes the sheet.
    ///
    /// Does nothing without a pending review or while a submit or discard is in progress. On failure, sets
    /// `reviewError`.
    func discardReview() async {
        guard let reviewID = reviewContext?.pendingReviewID, !isSubmittingReview else { return }
        isSubmittingReview = true
        reviewError = nil
        defer { isSubmittingReview = false }
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
        // Only write when it changes, so a held j or k doesn't redraw the status line on every repeat.
        if diffNotice != nil { diffNotice = nil }
        holdCursorUntil = .now + 0.5
        scrollRequest = ScrollRequest(path: path, lineID: lineID, placement: placement)
    }

    /// Puts the cursor on the selected file's first line and ends any selection.
    private func resetCursor() {
        cursorLineID = selectedFile?.cursorLines.first?.id
        selectionAnchor = nil
        diffNotice = nil
    }

    /// Moves the cursor by some number of lines, stopping at the first and last.
    ///
    /// - Parameter offset: How many lines to move; negative moves up.
    /// - Returns: False if the file has no lines.
    private func moveCursor(by offset: Int) -> Bool {
        guard let lines = selectedFile?.cursorLines, !lines.isEmpty else { return false }
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
        let stops = Set(file.cursorLines.map(\.id))
        let visible = visibleIDs.filter(stops.contains).sorted()
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
        guard canScrollDiff, let lines = selectedFile?.cursorLines else { return false }
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
            showFile(path)
            focusedThreadID = nil
        }
        collapsedDirectories = collapsedDirectories.filter { !path.hasPrefix($0 + "/") }
    }

    /// Makes a file the selected one, with the cursor on its first line.
    ///
    /// - Parameter path: The file's path, or nil for no selection.
    private func showFile(_ path: String?) {
        selectedPath = path
        // The old cursor's ID means nothing in the new file, so drop it before building the file's view.
        cursorLineID = nil
        selectionAnchor = nil
        prepareFullFile()
        resetCursor()
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
        guard let file = displayedFile(at: thread.path), let line = thread.line,
            let id = file.lineID(side: thread.side, line: line)
        else { return }
        selectionAnchor = nil
        placeCursor(id, placement: .center)
    }

    // MARK: Whole-file view

    /// Returns whether a file is set to show in full: its own toggle, or else `showsFullFiles`.
    ///
    /// - Parameter path: The file's path in the PR's head.
    /// - Returns: True to show the whole file, false for just the hunks.
    func wantsFullFile(_ path: String) -> Bool {
        fullFileOverrides[path] ?? showsFullFiles
    }

    /// A status line for the selected file's whole-file view: loading, or why it couldn't be shown.
    var fullFileStatus: String? {
        guard let path = selectedPath, wantsFullFile(path), fullFiles[path] == nil else { return nil }
        if loadingFullFiles.contains(path) { return "Loading the full file…" }
        return fullFileErrors[path]
    }

    /// Switches the selected file between its hunks and the whole file, keeping the cursor on the same line.
    ///
    /// - Returns: False if no file is selected.
    private func toggleFullFile() -> Bool {
        guard let path = selectedPath else { return false }
        let full = !wantsFullFile(path)
        preservingCursor {
            fullFileOverrides[path] = full == showsFullFiles ? nil : full
            prepareFullFile()
        }
        return true
    }

    /// Shows every file in full, or every file as hunks, clearing the per-file toggles.
    ///
    /// - Parameter full: Whether files should show in full.
    /// - Returns: Always true; the command applies whenever the Files tab is showing.
    private func setAllFilesFull(_ full: Bool) -> Bool {
        preservingCursor {
            showsFullFiles = full
            fullFileOverrides = [:]
            prepareFullFile()
        }
        return true
    }

    /// Builds the selected file's whole-file view if it's set to show in full, fetching its contents if needed.
    ///
    /// Added and deleted files are already whole in the diff, so they need no fetch. Fetched contents are kept per
    /// commit, so refreshing an unchanged PR doesn't fetch them again. Failures land in `fullFileErrors`, and the file
    /// keeps showing its hunks.
    ///
    /// A view built right away replaces the displayed file without moving the cursor, so callers wrap this in
    /// `preservingCursor(_:)` or reset the cursor. A view built after a fetch keeps the cursor on its line itself.
    private func prepareFullFile() {
        guard let path = selectedPath, wantsFullFile(path), fullFiles[path] == nil, let file = filesByPath[path],
            !file.isBinary, !loadingFullFiles.contains(path)
        else { return }
        guard file.needsContentsForFullFile else {
            fullFiles[path] = file.fullFile(headText: "")
            return
        }
        guard let commit = diffCommitID else { return }
        let key = "\(commit):\(path)"
        if let text = headTexts[key] {
            buildFullFile(file, headText: text)
            return
        }
        loadingFullFiles.insert(path)
        fullFileErrors[path] = nil
        Task {
            defer { loadingFullFiles.remove(path) }
            do {
                let text = try await GitHubCLI().fileContents(of: pr, path: path, commitID: commit)
                headTexts[key] = text
                // A refresh may have replaced the diff while this loaded; build against the current one.
                if let current = filesByPath[path], diffCommitID == commit {
                    preservingCursor { buildFullFile(current, headText: text) }
                }
            } catch {
                fullFileErrors[path] = "Couldn't load the full file: \(error.localizedDescription)"
            }
        }
    }

    /// Stores a file's whole-file view built from its contents, or records why it couldn't be built.
    ///
    /// Like `prepareFullFile()`, it leaves the cursor alone.
    ///
    /// - Parameters:
    ///   - file: The file's diff.
    ///   - headText: The file's contents at the PR's head commit.
    private func buildFullFile(_ file: FileDiff, headText: String) {
        guard let full = file.fullFile(headText: headText) else {
            fullFileErrors[file.path] = "The file on GitHub doesn't match this diff. Refresh to load the latest changes."
            return
        }
        fullFiles[file.path] = full
    }

    /// Makes a change to how the selected file is shown, then puts the cursor and selection back on the same lines.
    ///
    /// Hunks and whole-file views number lines differently, so lines are matched by their line numbers. When the cursor
    /// was on a line the new view doesn't have, it moves to the nearest line after it.
    ///
    /// - Parameter change: The change, which may replace the selected file's displayed diff.
    private func preservingCursor(_ change: () -> Void) {
        let before = selectedFile
        let cursorLine = cursorLineID.flatMap { before?.line(withID: $0) }
        let anchorLine = selectionAnchor.flatMap { before?.line(withID: $0) }
        change()
        guard let after = selectedFile, after != before else { return }
        selectionAnchor = anchorLine.flatMap(after.lineID(matching:))
        guard let cursorLine else {
            resetCursor()
            return
        }
        let lines = after.cursorLines
        let position = { (line: DiffLine) in line.newLine ?? line.oldLine ?? 0 }
        let id =
            after.lineID(matching: cursorLine)
            ?? lines.first { position($0) >= position(cursorLine) }?.id
            ?? lines.last?.id
        if let id { placeCursor(id, placement: .center) }
    }
}
