// The review queue: the app's main window.
//
// Lists open PRs in sections, one per search: review requested, yours, involving you, and any searches from
// `config.toml`. It opens a review window for any of them, and opens PR URLs passed on the command line at launch. The
// sections live in `ReviewQueue`, shared by every queue window, so a new window (such as the one a Dock click opens)
// shows the last results at once.

import MaserCore
import Observation
import SwiftUI

/// The queue's searches and their results, shared by every queue window and kept between them.
@MainActor @Observable
final class ReviewQueue {
    /// The app's single queue.
    static let shared = ReviewQueue()

    /// One section per search, in queue order, before de-duplication and filtering; `nil` before the first load.
    private(set) var sections: [QueueSection]?
    /// Whether a load is in progress.
    private(set) var isLoading = false
    /// When the sections last loaded.
    private var loadedAt: Date?
    /// The searches the load in progress is running, if any.
    private var loadingSearches: [PullRequestSearch]?
    /// Set when the searches change during a load, so it runs again with the new ones.
    private var needsReload = false

    /// Only `shared` exists.
    private init() {}

    /// Runs the configured searches in parallel, keeping the current results on screen meanwhile.
    ///
    /// A search that fails keeps its last results and shows the error; the others still update.
    ///
    /// - Parameter maxAge: Skip the fetch if the queue loaded less than this many seconds ago with the same searches;
    ///   `0` always fetches.
    func refresh(maxAge: TimeInterval = 0) async {
        let searches = ConfigStore.shared.settings.queueSearches
        guard !isLoading else {
            needsReload = needsReload || searches != loadingSearches
            return
        }
        if let loadedAt, Date.now.timeIntervalSince(loadedAt) < maxAge, searches == sections?.map(\.search) { return }
        isLoading = true
        defer {
            isLoading = false
            loadingSearches = nil
        }
        repeat {
            needsReload = false
            let searches = ConfigStore.shared.settings.queueSearches
            loadingSearches = searches
            await load(searches)
        } while needsReload
    }

    /// Runs searches and replaces the sections with their results.
    ///
    /// - Parameter searches: The searches, in queue order.
    private func load(_ searches: [PullRequestSearch]) async {
        let previous = Dictionary((sections ?? []).map { ($0.id, $0.prs) }, uniquingKeysWith: { first, _ in first })
        let results = await withTaskGroup(of: (Int, Result<[PullRequest], any Error>).self) { group in
            let cli = GitHubCLI()
            for (index, search) in searches.enumerated() {
                group.addTask {
                    do { return (index, .success(try await cli.searchPullRequests(search))) } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results: [Int: Result<[PullRequest], any Error>] = [:]
            for await (index, result) in group { results[index] = result }
            return results
        }
        sections = searches.enumerated().map { index, search in
            switch results[index] {
            case let .success(prs): QueueSection(search: search, prs: prs)
            case let .failure(error):
                QueueSection(search: search, prs: previous[search.id] ?? nil, error: error.localizedDescription)
            case nil: QueueSection(search: search, prs: previous[search.id] ?? nil)
            }
        }
        loadedAt = .now
    }
}

/// Lists open PRs in sections, with a filter box.
struct ReviewQueueView: View {
    /// The parts of the window that take keyboard focus.
    private enum Focus: Hashable { case list, filter }

    private let queue = ReviewQueue.shared
    @State private var selection: Set<PullRequest.ID> = []
    /// The filter box's text; every word must match a PR.
    @State private var filter = ""
    @FocusState private var focus: Focus?
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    /// Whether launch arguments were already handled, so a second queue window doesn't reopen them.
    @MainActor private static var openedLaunchArguments = false

    var body: some View {
        let sections = queue.sections.map { QueueSection.displayed($0, filter: filter) }
        VStack(spacing: 0) {
            filterBar
            Divider()
            content(sections)
        }
        .navigationTitle("Pull Requests")
        .toolbar {
            Button("Open Pull Request…", systemImage: "plus") {
                openWindow(id: OpenPullRequestView.windowID)
            }
            .help("Open Pull Request…", .openPullRequest)
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await queue.refresh() }
            }
            .help("Refresh", .refresh)
            .disabled(queue.isLoading)
        }
        .focusedSceneValue(\.refreshAction, RefreshAction { Task { await queue.refresh() } })
        .focusedSceneValue(\.filterAction, FilterAction { focus = .filter })
        .commandHandler { perform($0, in: sections ?? []) }
        .configProblemsBanner()
        .defaultFocus($focus, .list)
        .task { await openLaunchArguments() }
        // A new window shows the last results right away and only refetches if they're more than a minute old.
        // Changing the searches in config.toml reloads at once.
        .task(id: ConfigStore.shared.settings.queueSearches) { await queue.refresh(maxAge: 60) }
    }

    /// The filter box.
    ///
    /// Return or Esc goes back to the list; Esc also clears the filter.
    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("Filter by title, repository, author or #number", text: $filter)
                .textFieldStyle(.plain)
                .focused($focus, equals: .filter)
                .onSubmit { focus = .list }
                .onExitCommand {
                    filter = ""
                    focus = .list
                }
            if queue.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .help("Filter Pull Requests", .filter)
    }

    /// Runs a vim-style key's command in the queue.
    ///
    /// - Parameters:
    ///   - command: The command to run.
    ///   - sections: The sections as shown, for moving the selection.
    /// - Returns: False for commands that don't apply here, so the key falls through.
    private func perform(_ command: CommandID, in sections: [QueueSection]) -> Bool {
        let prs = sections.flatMap { $0.prs ?? [] }
        let index = prs.lastIndex { selection.contains($0.id) }
        switch command {
        case .refresh: Task { await queue.refresh() }
        case .filter: focus = .filter
        case .cancel:
            guard !filter.isEmpty else { return false }
            filter = ""
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

    /// Selects one PR, clamped to the list, and gives the list focus so Return opens it.
    ///
    /// - Parameters:
    ///   - prs: The PRs as shown, in order.
    ///   - index: The position to select.
    private func select(_ prs: [PullRequest], at index: Int) {
        guard !prs.isEmpty else { return }
        selection = [prs[min(max(index, 0), prs.count - 1)].id]
        focus = .list
    }

    /// Opens a review window for each PR URL passed on the command line (`swift run Maser <url>…`), once per launch.
    ///
    /// Arguments that aren't PR URLs are ignored, and so are PRs that fail to load.
    private func openLaunchArguments() async {
        guard !Self.openedLaunchArguments else { return }
        Self.openedLaunchArguments = true
        let urls = CommandLine.arguments.dropFirst().compactMap(URL.init(string:))
            .filter { PullRequest.nameWithOwner(fromURL: $0) != nil }
        guard !urls.isEmpty else { return }
        let cli = GitHubCLI()
        for url in urls {
            if let pr = try? await cli.pullRequest(url: url) {
                openWindow(value: pr)
            }
        }
    }

    /// The sections, or a progress or empty state.
    ///
    /// - Parameter sections: The sections as shown, or `nil` before the first load.
    /// - Returns: The list, or a placeholder.
    @ViewBuilder
    private func content(_ sections: [QueueSection]?) -> some View {
        if let sections, !sections.isEmpty {
            list(sections)
        } else if sections != nil, !filter.isEmpty {
            ContentUnavailableView.search(text: filter)
        } else if sections != nil {
            ContentUnavailableView(
                "Nothing to review", systemImage: "checkmark.circle",
                description: Text(emptyDescription))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What the queue searched, for the empty state.
    private var emptyDescription: String {
        let names = (queue.sections ?? []).map { $0.search.name.lowercased() }
        guard !names.isEmpty else { return "The queue has no searches. Add some under [queue] in config.toml." }
        return "No open pull requests in: \(names.joined(separator: ", ")). Add searches under [queue] in config.toml."
    }

    /// The sections as a selectable list; double-click or Return opens the selected PRs.
    ///
    /// - Parameter sections: The sections to show, already de-duplicated and filtered.
    /// - Returns: The list.
    private func list(_ sections: [QueueSection]) -> some View {
        let prs = sections.flatMap { $0.prs ?? [] }
        return ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(sections) { section in
                    Section {
                        if let error = section.error {
                            Label("Couldn't search: \(error)", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .selectionDisabled()
                        }
                        ForEach(section.prs ?? []) { pr in
                            PullRequestRow(pr: pr)
                        }
                    } header: {
                        SectionHeader(search: section.search, count: section.prs?.count ?? 0)
                    }
                }
            }
            .focused($focus, equals: .list)
            .contextMenu(forSelectionType: PullRequest.ID.self) { ids in
                Button("Review") { review(ids, in: prs) }
                // A PR's ID is its github.com URL.
                Button("Open on GitHub") { ids.forEach { openURL($0) } }
            } primaryAction: { ids in
                review(ids, in: prs)  // Double-click or Return.
            }
            .onChange(of: selection) { _, ids in
                if ids.count == 1, let id = ids.first { proxy.scrollTo(id) }
            }
        }
    }

    /// Opens a review window for each selected PR.
    ///
    /// - Parameters:
    ///   - ids: The selected PRs.
    ///   - prs: The shown PRs to look the IDs up in.
    private func review(_ ids: Set<PullRequest.ID>, in prs: [PullRequest]) {
        for pr in prs where ids.contains(pr.id) {
            openWindow(value: pr)
        }
    }
}

/// A section's heading: its name, how many PRs it shows, and its query as a tooltip.
private struct SectionHeader: View {
    let search: PullRequestSearch
    let count: Int

    var body: some View {
        HStack {
            Text(search.name)
            Text("\(count)").foregroundStyle(.tertiary)
        }
        .help(search.query)
    }
}

/// One PR in the queue: title, draft marker, and repository, number, author and last update.
private struct PullRequestRow: View {
    let pr: PullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(pr.title).font(.headline)
                if pr.isDraft {
                    Text("Draft").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(
                "\(pr.repository.nameWithOwner) #\(pr.number) · \(pr.author.login) · updated \(pr.updatedAt, style: .relative) ago"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
