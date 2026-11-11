// The main window: the review queue in a sidebar, and the open PR's review beside it.
//
// `MainView` is the window's root. Selecting a PR in the sidebar shows its review in the detail column, and reviews
// stay loaded, so going back to one is instant. The window has one vim-style key handler, which sends keys to the queue
// while the sidebar has focus and to the review otherwise. `MainWindows` tracks the open main windows, so Show Pull
// Requests and Open Pull Request can bring one forward instead of opening another.

import AppKit
import MaserCore
import Observation
import SwiftUI

/// One main window's state: which PR it shows, the reviews it has loaded, and requests to focus the queue.
@MainActor @Observable
final class MainWindowState {
    /// The PR in the detail column, if any.
    private(set) var openPR: PullRequest?
    /// The review of every PR shown in this window so far, kept so going back to one doesn't reload it.
    private var reviews: [PullRequest.ID: ReviewModel] = [:]
    /// Whether the sidebar is showing.
    var columnVisibility = NavigationSplitViewVisibility.all
    /// Bumped to ask the window to show the sidebar and focus the list.
    private(set) var queueFocusRequest = 0
    /// Whether vim-style keys go to the queue rather than the open review.
    ///
    /// Tracked here rather than read from keyboard focus: AppKit doesn't always move focus to the list when asked.
    var queueHasKeys = true

    /// The review in the detail column.
    var openReview: ReviewModel? { openPR.flatMap { reviews[$0.id] } }

    /// Shows a PR's review in the detail column, creating it the first time.
    ///
    /// - Parameters:
    ///   - pr: The pull request to show.
    ///   - takeKeys: Whether the review gets the keys. False while moving through the queue with keys, which shows
    ///     each PR without leaving the queue.
    func open(_ pr: PullRequest, takeKeys: Bool = true) {
        if reviews[pr.id] == nil { reviews[pr.id] = ReviewModel(pr: pr) }
        openPR = pr
        if takeKeys { queueHasKeys = false }
    }

    /// Shows the sidebar and gives the queue the keys.
    func focusQueue() {
        columnVisibility = .all
        queueHasKeys = true
        queueFocusRequest += 1
    }

    /// Hides the sidebar and gives the open review the keys; does nothing with no review open.
    func hideQueue() {
        guard openReview != nil else { return }
        columnVisibility = .detailOnly
        queueHasKeys = false
    }
}

/// The open main windows, so app-wide commands can reach one.
@MainActor
final class MainWindows {
    /// The app's single registry.
    static let shared = MainWindows()

    /// Each main window's state; weak keys, so closed windows drop out once they're freed.
    private let windows = NSMapTable<NSWindow, MainWindowState>.weakToStrongObjects()
    /// A PR to show in the next main window that appears, when none was open to show it in.
    private var pending: PullRequest?

    /// Only `shared` exists.
    private init() {}

    /// Records a main window and its state; repeat calls are fine.
    ///
    /// - Parameters:
    ///   - window: The window.
    ///   - state: Its state.
    func register(_ window: NSWindow, state: MainWindowState) {
        windows.setObject(state, forKey: window)
    }

    /// Hands over the PR waiting for a new window, if any.
    ///
    /// - Returns: The PR, which is then no longer pending.
    func takePending() -> PullRequest? {
        defer { pending = nil }
        return pending
    }

    /// Brings a main window forward with the sidebar focused, opening one if none is open.
    ///
    /// - Parameter openWindow: Opens a new main window when needed.
    func showQueue(openWindow: OpenWindowAction) {
        if let (window, state) = frontmost() {
            bringForward(window)
            state.focusQueue()
        } else {
            openWindow(id: MainView.windowID)
        }
    }

    /// Shows a PR in the frontmost main window, opening one if none is open.
    ///
    /// - Parameters:
    ///   - pr: The pull request to show.
    ///   - openWindow: Opens a new main window when needed.
    func show(_ pr: PullRequest, openWindow: OpenWindowAction) {
        if let (window, state) = frontmost() {
            bringForward(window)
            state.open(pr)
        } else {
            pending = pr
            openWindow(id: MainView.windowID)
        }
    }

    /// The window showing a main window state, if it's still open.
    ///
    /// - Parameter state: The state.
    /// - Returns: The window.
    func window(for state: MainWindowState) -> NSWindow? {
        windows.keyEnumerator().allObjects.lazy.compactMap { $0 as? NSWindow }.first { windows.object(forKey: $0) === state }
    }

    /// The main window nearest the front that's still open, with its state.
    private func frontmost() -> (NSWindow, MainWindowState)? {
        // Closed SwiftUI windows can linger before they're freed, so only count visible or minimized ones.
        for window in NSApp.orderedWindows where window.isVisible || window.isMiniaturized {
            if let state = windows.object(forKey: window) { return (window, state) }
        }
        return nil
    }

    /// Makes a window key and brings it to the front, un-minimizing it first.
    ///
    /// - Parameter window: The window.
    private func bringForward(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// The main window's root: the queue in a sidebar, and the open PR's review in the detail column.
struct MainView: View {
    /// The scene ID used to open main windows.
    static let windowID = "main"

    @State private var state = MainWindowState()
    @State private var selection: Set<PullRequest.ID> = []
    /// The queue's filter text; every word must match a PR.
    @State private var filter = ""
    @FocusState private var focus: QueueFocus?
    private let queue = ReviewQueue.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    /// Whether launch arguments were already handled, so a second main window doesn't reopen them.
    @MainActor private static var openedLaunchArguments = false

    var body: some View {
        let sections = queue.sections.map { QueueSection.displayed($0, filter: filter) }
        NavigationSplitView(columnVisibility: $state.columnVisibility) {
            QueueSidebar(
                sections: sections, selection: $selection, filter: $filter, focus: $focus,
                openID: state.openPR?.id, open: open
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 320)
        } detail: {
            detail
        }
        .background(WindowReader { [state] in MainWindows.shared.register($0, state: state) })
        .commandHandler { perform($0, in: sections ?? []) }
        .focusedSceneValue(\.refreshAction, RefreshAction { refresh() })
        .focusedSceneValue(\.filterAction, FilterAction { focusFilter() })
        .configProblemsBanner()
        // No `defaultFocus`: it pulled focus back to the list whenever a comment box took it.
        .onAppear {
            // With no review to show, a sidebar restored as hidden would leave an empty window.
            if state.openReview == nil {
                state.columnVisibility = .all
                focus = .list
            }
        }
        .onChange(of: state.queueFocusRequest) {
            // Start j/k from the open PR, and highlight the list. Setting focus directly doesn't always take, so clear
            // it first; the keys go to the queue either way.
            if selection.isEmpty, let id = state.openPR?.id { selection = [id] }
            focus = nil
            Task {
                await Task.yield()
                focus = .list
            }
        }
        .onChange(of: focus) { old, new in
            // Leaving the filter box with Return or Esc keeps the keys in the queue.
            if old == .filter, new == .list { state.queueHasKeys = true }
        }
        // A click shows the PR right away and gives it the keys; the queue gets them back only when clicked again or
        // asked for (⌘0, g p).
        .onChange(of: selection) { _, ids in
            guard Self.isMouseEvent(NSApp.currentEvent), ids.count == 1, let id = ids.first,
                let pr = sections?.lazy.compactMap(\.prs).joined().first(where: { $0.id == id })
            else { return }
            open([pr], newWindow: false)
        }
        // Moving through the list with keys shows a PR once the selection settles, so passing PRs aren't all loaded.
        .task(id: selection) {
            guard selection.count == 1, let id = selection.first, id != state.openPR?.id,
                let pr = sections?.lazy.compactMap(\.prs).joined().first(where: { $0.id == id })
            else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            state.open(pr, takeKeys: false)
        }
        .task {
            if let pr = MainWindows.shared.takePending() { state.open(pr) }
            await openLaunchArguments()
        }
        #if DEBUG
            .task {
                // A debug build launched by scripts/check-ui runs a UI scenario in the first main window.
                await UIScenarioRunner.runIfRequested(
                    MainWindowProbe(
                        state: state, selection: { selection },
                        sections: { queue.sections.map { QueueSection.displayed($0, filter: filter) } ?? [] }))
            }
        #endif
        // A new window shows the last results right away and only refetches if they're more than a minute old.
        // Changing the searches in config.toml reloads at once.
        .task(id: ConfigStore.shared.settings.queueSearches) { await queue.refresh(maxAge: 60) }
    }

    /// The open PR's review, or a placeholder.
    @ViewBuilder
    private var detail: some View {
        if let review = state.openReview {
            ReviewView(model: review)
                .id(review.pr.id)
                // Clicking the review gives it the keys.
                .simultaneousGesture(
                    TapGesture().onEnded {
                        state.queueHasKeys = false
                        if focus == .list { focus = nil }
                    })
        } else {
            ContentUnavailableView(
                "No pull request open", systemImage: "arrow.triangle.pull",
                description: Text("Pick one from the list, or open one by URL with ⌘O.")
            )
            .navigationTitle("Pull Requests")
        }
    }

    /// Whether an event is a mouse click, to tell clicking a PR from moving to it with keys.
    ///
    /// - Parameter event: The event being handled, if any.
    /// - Returns: True for left mouse-down and mouse-up events; a right click only opens the context menu.
    private static func isMouseEvent(_ event: NSEvent?) -> Bool {
        event?.type == .leftMouseDown || event?.type == .leftMouseUp
    }

    /// Whether vim-style keys go to the queue: when it has them, or no PR is open.
    private var keysGoToQueue: Bool { state.queueHasKeys || state.openReview == nil }

    /// Runs a vim-style key's command in the queue or the open review.
    ///
    /// While the queue has the keys it gets each one first, and the review gets the ones it doesn't use.
    ///
    /// - Parameters:
    ///   - command: The command to run.
    ///   - sections: The queue's sections as shown.
    /// - Returns: False for commands that don't apply, so the key falls through.
    private func perform(_ command: CommandID, in sections: [QueueSection]) -> Bool {
        switch command {
        case .togglePullRequests:
            // Hidden: show it with the keys. Showing: hide it, unless there's no review to show instead.
            if state.columnVisibility == .detailOnly || state.openReview == nil {
                state.focusQueue()
            } else {
                state.hideQueue()
                focus = nil
            }
            return true
        // `/` only filters while the queue has the keys, so a stray press in the diff does nothing.
        case .filter where !keysGoToQueue: return true
        default: break
        }
        // Keys the queue doesn't use (c, g f, S…) go on to the open review.
        if keysGoToQueue, performInQueue(command, in: sections) { return true }
        return state.openReview?.perform(command) ?? false
    }

    /// Runs a command in the queue sidebar.
    ///
    /// - Parameters:
    ///   - command: The command to run.
    ///   - sections: The sections as shown, for moving the selection.
    /// - Returns: False for commands that don't apply here.
    private func performInQueue(_ command: CommandID, in sections: [QueueSection]) -> Bool {
        let prs = sections.flatMap { $0.prs ?? [] }
        let index = prs.lastIndex { selection.contains($0.id) }
        switch command {
        case .refresh: Task { await queue.refresh() }
        case .filter: focusFilter()
        case .openSelected:
            let chosen = prs.filter { selection.contains($0.id) }
            guard !chosen.isEmpty else { return false }
            open(chosen, newWindow: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
        case .cancel:
            // Esc clears the filter, then hands the keys back to the open review.
            if !filter.isEmpty {
                filter = ""
            } else if state.openReview != nil {
                state.queueHasKeys = false
                focus = nil
            } else {
                return false
            }
        case .cursorDown: select(prs, at: index.map { $0 + 1 } ?? 0)
        case .cursorUp: select(prs, at: index.map { $0 - 1 } ?? 0)
        case .scrollToTop: select(prs, at: 0)
        case .scrollToBottom: select(prs, at: prs.count - 1)
        // In the queue, ] and [ move between sections rather than files.
        case .nextFile, .previousFile:
            if let target = QueueSection.sectionStart(from: index, in: sections, forward: command == .nextFile) {
                select(prs, at: target)
            }
        case .openOnGitHub:
            for pr in prs where selection.contains(pr.id) { openURL(pr.url) }
        default: return false
        }
        return true
    }

    /// Selects one PR in the queue, clamped to the list, and gives the list focus.
    ///
    /// - Parameters:
    ///   - prs: The PRs as shown, in order.
    ///   - index: The position to select.
    private func select(_ prs: [PullRequest], at index: Int) {
        guard !prs.isEmpty else { return }
        selection = [prs[min(max(index, 0), prs.count - 1)].id]
        focus = .list
    }

    /// Opens PRs chosen in the queue.
    ///
    /// - Parameters:
    ///   - prs: The chosen PRs.
    ///   - newWindow: Whether to open each in a window of its own; otherwise the first shows here and takes the keys.
    private func open(_ prs: [PullRequest], newWindow: Bool) {
        if newWindow {
            prs.forEach { openWindow(value: $0) }
        } else if let pr = prs.first {
            state.open(pr)
            focus = nil
        }
    }

    /// Refreshes whatever has the keys: the queue, or the open review.
    private func refresh() {
        if keysGoToQueue {
            Task { await queue.refresh() }
        } else if let review = state.openReview {
            Task { await review.load() }
        }
    }

    /// Shows the sidebar and focuses the filter box, giving the queue the keys.
    private func focusFilter() {
        state.columnVisibility = .all
        state.queueHasKeys = true
        focus = .filter
    }

    /// Opens the PR URLs passed on the command line (`swift run Maser <url>…`), once per launch.
    ///
    /// The first shows in this window, and the rest each in a window of their own. Arguments that aren't PR URLs are
    /// ignored, and so are PRs that fail to load.
    private func openLaunchArguments() async {
        guard !Self.openedLaunchArguments else { return }
        Self.openedLaunchArguments = true
        let urls = CommandLine.arguments.dropFirst().compactMap(URL.init(string:))
            .filter { PullRequest.nameWithOwner(fromURL: $0) != nil }
        let cli = GitHubCLI()
        var prs: [PullRequest] = []
        for url in urls {
            if let pr = try? await cli.pullRequest(url: url) { prs.append(pr) }
        }
        guard let first = prs.first else { return }
        state.open(first)
        focus = nil
        prs.dropFirst().forEach { openWindow(value: $0) }
    }
}
