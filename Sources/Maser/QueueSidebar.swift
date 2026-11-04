// The review queue: the main window's sidebar.
//
// Lists open PRs in sections, one per search: review requested, yours, involving you, and any searches from
// `config.toml`, with a filter box on top. The sections live in `ReviewQueue`, shared by every main window, so a new
// window (such as the one a Dock click opens) shows the last results at once. `MainView` owns the selection, filter
// and focus, and handles the queue's keys.

import MaserCore
import Observation
import SwiftUI

/// The queue's searches and their results, shared by every main window and kept between them.
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

/// The parts of the queue sidebar that take keyboard focus.
enum QueueFocus: Hashable {
    /// The list of PRs.
    case list
    /// The filter box.
    case filter
}

/// The queue's sections as a sidebar list, with a filter box and the queue's toolbar buttons.
struct QueueSidebar: View {
    /// The sections as shown, already de-duplicated and filtered; `nil` before the first load.
    let sections: [QueueSection]?
    @Binding var selection: Set<PullRequest.ID>
    @Binding var filter: String
    var focus: FocusState<QueueFocus?>.Binding
    /// The PR showing in the detail column, marked in the list.
    let openID: PullRequest.ID?
    /// Opens PRs: in the detail column, or with `newWindow` each in a window of its own.
    let open: (_ prs: [PullRequest], _ newWindow: Bool) -> Void

    private let queue = ReviewQueue.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Open Pull Request…", systemImage: "plus") {
                    openWindow(id: OpenPullRequestView.windowID)
                }
                .help("Open Pull Request…", .openPullRequest)
                Button("Refresh Pull Requests", systemImage: "arrow.clockwise") {
                    Task { await queue.refresh() }
                }
                .help("Refresh Pull Requests", .refresh)
                .disabled(queue.isLoading)
            }
        }
    }

    /// The filter box.
    ///
    /// Return goes back to the list; Esc clears the filter and goes back to the list.
    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .focused(focus, equals: .filter)
                .onSubmit { focus.wrappedValue = .list }
                .onExitCommand {
                    filter = ""
                    focus.wrappedValue = .list
                }
            if queue.isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .help("Filter by title, repository, author or #number", .filter)
    }

    /// The sections, or a progress or empty state.
    @ViewBuilder
    private var content: some View {
        if let sections, !sections.isEmpty {
            list(sections)
        } else if sections != nil, !filter.isEmpty {
            ContentUnavailableView.search(text: filter)
        } else if sections != nil {
            ContentUnavailableView(
                "Nothing to review", systemImage: "checkmark.circle", description: Text(emptyDescription))
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

    /// The sections as a selectable list.
    ///
    /// Return or double-click opens the selected PRs; ⌥ with either opens each in a new window.
    ///
    /// - Parameter sections: The sections to show.
    /// - Returns: The list.
    private func list(_ sections: [QueueSection]) -> some View {
        let prs = sections.flatMap { $0.prs ?? [] }
        let chosen = { (ids: Set<PullRequest.ID>) in prs.filter { ids.contains($0.id) } }
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
                            PullRequestRow(pr: pr, isOpen: pr.id == openID)
                        }
                    } header: {
                        SectionHeader(search: section.search, count: section.prs?.count ?? 0)
                    }
                }
            }
            .listStyle(.sidebar)
            .focused(focus, equals: .list)
            .contextMenu(forSelectionType: PullRequest.ID.self) { ids in
                Button("Review") { open(chosen(ids), false) }
                Button("Open in New Window") { open(chosen(ids), true) }
                // A PR's ID is its github.com URL.
                Button("Open on GitHub") { ids.forEach { openURL($0) } }
            } primaryAction: { ids in
                // Double-click or Return.
                open(chosen(ids), NSEvent.modifierFlags.contains(.option))
            }
            .onChange(of: selection) { _, ids in
                if ids.count == 1, let id = ids.first { proxy.scrollTo(id) }
            }
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
    /// Whether the PR is the one showing in the detail column.
    let isOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(pr.title).font(.headline).lineLimit(2)
                if pr.isDraft {
                    Text("Draft").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("\(pr.repository.nameWithOwner) #\(pr.number) · \(pr.author.login)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("updated \(pr.updatedAt, style: .relative) ago")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .padding(.leading, 6)
        .overlay(alignment: .leading) {
            // Marks the PR the detail column shows, which may not be the selected one.
            if isOpen { Capsule().fill(Color.accentColor).frame(width: 3) }
        }
    }
}
