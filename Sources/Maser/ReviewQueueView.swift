// The review queue: the app's main window.
//
// Lists the open PRs where the user's review is requested, newest activity first, and opens a review window for any of
// them. It also opens PR URLs passed on the command line at launch. The list lives in `ReviewQueue`, shared by every
// queue window, so a new window (such as the one a Dock click opens) shows the last list at once.

import MaserCore
import Observation
import SwiftUI

/// The PRs awaiting the user's review, shared by every queue window and kept between them.
@MainActor @Observable
final class ReviewQueue {
    /// The app's single queue.
    static let shared = ReviewQueue()

    /// The PRs from the last successful load, most recently updated first; `nil` before the first one.
    private(set) var prs: [PullRequest]?
    /// The message from the last failed load, cleared by the next successful one.
    private(set) var error: String?
    /// Whether a load is in progress.
    private(set) var isLoading = false
    /// When the list last loaded successfully.
    private var loadedAt: Date?

    /// Only `shared` exists.
    private init() {}

    /// Fetches the PRs awaiting review, keeping the current list on screen meanwhile.
    ///
    /// - Parameter maxAge: Skip the fetch if the list loaded less than this many seconds ago; `0` always fetches.
    func refresh(maxAge: TimeInterval = 0) async {
        guard !isLoading else { return }
        if let loadedAt, Date.now.timeIntervalSince(loadedAt) < maxAge { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let prs = try await GitHubCLI().reviewRequests()
            self.prs = prs.sorted { $0.updatedAt > $1.updatedAt }
            error = nil
            loadedAt = .now
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Lists open PRs awaiting the user's review.
struct ReviewQueueView: View {
    private let queue = ReviewQueue.shared
    @State private var selection: Set<PullRequest.ID> = []
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    /// Whether launch arguments were already handled, so a second queue window doesn't reopen them.
    @MainActor private static var openedLaunchArguments = false

    var body: some View {
        content
            .navigationTitle("Review Requests")
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
            .commandHandler { command in
                guard command == .refresh else { return false }
                Task { await queue.refresh() }
                return true
            }
            .configProblemsBanner()
            .task { await openLaunchArguments() }
            // A new window shows the last list right away and only refetches if it's more than a minute old.
            .task { await queue.refresh(maxAge: 60) }
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

    /// The list, or a progress, error or empty state.
    ///
    /// A failed refresh keeps the last list and shows the error above it.
    @ViewBuilder
    private var content: some View {
        if let prs = queue.prs {
            VStack(spacing: 0) {
                if let error = queue.error {
                    Label("Couldn't refresh: \(error)", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Divider()
                }
                if prs.isEmpty {
                    ContentUnavailableView("No reviews requested", systemImage: "checkmark.circle")
                } else {
                    list(prs)
                }
            }
        } else if let error = queue.error {
            ContentUnavailableView("Couldn't load PRs", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView()
        }
    }

    /// The PRs as a selectable list; double-click or Return opens them.
    private func list(_ prs: [PullRequest]) -> some View {
        List(prs, selection: $selection) { pr in
            PullRequestRow(pr: pr)
        }
        .contextMenu(forSelectionType: PullRequest.ID.self) { ids in
            Button("Review") { review(ids, in: prs) }
            // A PR's ID is its github.com URL.
            Button("Open on GitHub") { ids.forEach { openURL($0) } }
        } primaryAction: { ids in
            review(ids, in: prs)  // Double-click or Return.
        }
    }

    /// Opens a review window for each selected PR.
    ///
    /// - Parameters:
    ///   - ids: The selected PRs.
    ///   - prs: The loaded PRs to look the IDs up in.
    private func review(_ ids: Set<PullRequest.ID>, in prs: [PullRequest]) {
        for pr in prs where ids.contains(pr.id) {
            openWindow(value: pr)
        }
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
