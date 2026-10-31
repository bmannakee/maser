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
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .navigationTitle("Review Requests")
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await load() }
                }
                .keyboardShortcut("r")
            }
            .task { await load() }
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
            List(prs) { pr in
                PullRequestRow(pr: pr)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { openURL(pr.url) }
            }
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
