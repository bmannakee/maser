// The review screen for one pull request, and the separate window that can hold one.
//
// `ReviewView` shows a `ReviewModel`'s Overview or Files tab, adds the toolbar, wires the model to the menu bar, and
// presents the Finish Review sheet. It usually fills the main window's detail column (see `MainView`); `ReviewWindow`
// puts one in a window of its own, for reviewing PRs side by side.

import MaserCore
import SwiftUI

/// A PR review, showing the Overview or Files tab with a toolbar to switch between them.
///
/// The toolbar picker, the menu bar and vim-style keys all switch tabs; the picker's tooltip lists the current
/// bindings. The view loads the PR's data when it appears, unless the model loaded it in the last minute. Whoever shows
/// it routes vim-style keys to the model, since a window has one key handler.
struct ReviewView: View {
    let model: ReviewModel

    /// The note shown when the PR left the queue but stayed open for its unsent text.
    static let leftQueueNote =
        "This PR is no longer in your queue: it may have been merged or closed. It stays open because it has text you haven't posted."

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.tab {
            case .overview: OverviewView(model: model)
            case .files: FilesView(model: model)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.leftQueue {
                Label(Self.leftQueueNote, systemImage: "tray.and.arrow.up")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.yellow.opacity(0.15))
                    .shownText("left-queue", Self.leftQueueNote)
            }
        }
        .navigationTitle(model.pr.title)
        .navigationSubtitle("\(model.pr.repository.nameWithOwner) #\(model.pr.number)")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.tab) {
                    ForEach(ReviewModel.Tab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .help(
                    ReviewModel.Tab.allCases.map { tab in
                        ConfigStore.shared.bindingSummary(for: tab.command).map { "\(tab.title): \($0)" } ?? tab.title
                    }.joined(separator: "\n"))
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.isFinishingReview = true
                } label: {
                    let count = model.pendingCommentCount
                    Label(count > 0 ? "Finish Review (\(count))" : "Review…", systemImage: "checkmark.bubble")
                        .labelStyle(.titleAndIcon)
                }
                .help("Finish Review", .submitReview)
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .help("Refresh", .refresh)
                Link(destination: model.pr.url) {
                    Label("Open on GitHub", systemImage: "safari")
                }
                .help("Open on GitHub", .openOnGitHub)
                if model.tab == .files {
                    Button("Comments", systemImage: "sidebar.right") {
                        model.showComments.toggle()
                    }
                    .help("Show/Hide Comments", .toggleComments)
                }
            }
        }
        .focusedSceneValue(\.reviewModel, model)
        .sheet(isPresented: $model.isFinishingReview) {
            FinishReviewView(model: model)
        }
        .task { await model.loadIfStale(maxAge: 60) }
    }
}

/// A window holding one PR's review, opened with Open in New Window to review PRs side by side.
struct ReviewWindow: View {
    /// The window's state, created once and kept for the window's lifetime.
    @State private var model: ReviewModel

    /// Creates a review window for a pull request; it loads the PR's data when it appears.
    ///
    /// - Parameter pr: The pull request to review.
    init(pr: PullRequest) {
        _model = State(initialValue: ReviewModel(pr: pr))
    }

    var body: some View {
        ReviewView(model: model)
            .focusedSceneValue(\.refreshAction, RefreshAction { [model] in Task { await model.load() } })
            .commandHandler { [model] in model.perform($0) }
            .configProblemsBanner()
    }
}
