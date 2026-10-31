import MaserCore
import SwiftUI

/// Lists open PRs awaiting the user's review.
struct ReviewQueueView: View {
    private enum LoadState {
        case loading
        case loaded([PullRequest])
        case failed(String)
    }

    @State private var state: LoadState = .loading
    @State private var selection: Set<PullRequest.ID> = []
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

    /// PR URLs passed on the command line (`swift run Maser <url>…`) are opened once at launch.
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
                    Task { await load() }
                }
                .help("Refresh", .refresh)
            }
            .focusedSceneValue(\.refreshAction, RefreshAction { Task { await load() } })
            .commandHandler { command in
                guard command == .refresh else { return false }
                Task { await load() }
                return true
            }
            .configProblemsBanner()
            .task { await openLaunchArguments() }
            .task { await load() }
    }

    private func openLaunchArguments() async {
        guard !Self.openedLaunchArguments else { return }
        Self.openedLaunchArguments = true
        let urls = CommandLine.arguments.dropFirst().compactMap(URL.init(string:))
            .filter { PullRequest.nameWithOwner(fromURL: $0) != nil }
        guard !urls.isEmpty, let cli = try? GitHubCLI() else { return }
        for url in urls {
            if let pr = try? await cli.pullRequest(url: url) {
                openWindow(value: pr)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
        case let .failed(message):
            ContentUnavailableView("Couldn't load PRs", systemImage: "exclamationmark.triangle", description: Text(message))
        case let .loaded(prs) where prs.isEmpty:
            ContentUnavailableView("No reviews requested", systemImage: "checkmark.circle")
        case let .loaded(prs):
            List(prs, selection: $selection) { pr in
                PullRequestRow(pr: pr)
            }
            .contextMenu(forSelectionType: PullRequest.ID.self) { ids in
                Button("Review") { review(ids, in: prs) }
                Button("Open on GitHub") { ids.forEach { openURL($0) } }
            } primaryAction: { ids in
                review(ids, in: prs) // double-click or Return
            }
        }
    }

    private func review(_ ids: Set<PullRequest.ID>, in prs: [PullRequest]) {
        for pr in prs where ids.contains(pr.id) {
            openWindow(value: pr)
        }
    }

    private func load() async {
        state = .loading
        do {
            let prs = try await GitHubCLI().reviewRequests()
            state = .loaded(prs.sorted { $0.updatedAt > $1.updatedAt })
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

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
            Text("\(pr.repository.nameWithOwner) #\(pr.number) · \(pr.author.login) · updated \(pr.updatedAt, style: .relative) ago")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
