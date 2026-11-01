import MaserCore
import SwiftUI

/// A PR review window. Tabs (toolbar, ⌘1/⌘2, `g o`/`g f`) switch between whole-window views.
struct ReviewView: View {
    @State private var model: ReviewModel

    init(pr: PullRequest) {
        _model = State(initialValue: ReviewModel(pr: pr))
    }

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.tab {
            case .overview: OverviewView(model: model)
            case .files: FilesView(model: model)
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
                .help(ReviewModel.Tab.allCases.map { tab in
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
        .focusedSceneValue(\.refreshAction, RefreshAction { [model] in Task { await model.load() } })
        .commandHandler { [model] in model.perform($0) }
        .configProblemsBanner()
        .sheet(isPresented: $model.isFinishingReview) {
            FinishReviewView(model: model)
        }
        .task { await model.load() }
    }
}
