import AppKit
import MaserCore
import SwiftUI

extension FocusedValues {
    /// The review window that has focus, if any.
    @Entry var reviewModel: ReviewModel?
    /// Reloads whatever the focused window shows.
    @Entry var refreshAction: RefreshAction?
}

struct RefreshAction {
    let perform: @MainActor () -> Void
}

/// Menu bar commands. Titles and shortcuts come from `CommandID` and the user's config.
struct MaserCommands: Commands {
    @FocusedValue(\.reviewModel) private var model
    @FocusedValue(\.refreshAction) private var refresh
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            global(.openConfig)
        }

        CommandGroup(after: .newItem) {
            global(.openPullRequest)
        }

        CommandGroup(before: .toolbar) {
            ForEach(ReviewModel.Tab.allCases) { tab in
                review(tab.command)
            }
            review(.toggleComments, title: model?.showComments == true ? "Hide Comments" : "Show Comments")
                .disabled(model?.tab != .files)
            Divider()
        }

        CommandMenu("Review") {
            CommandButton(.refresh) { refresh?.perform() }
                .disabled(refresh == nil)
            review(.openOnGitHub)
            review(.comment)
            review(.reply).disabled(model?.tab != .files)
            review(.submitReview)
            Divider()
            review(.nextFile)
            review(.previousFile)
            Divider()
            review(.nextThread)
            review(.previousThread)
            Divider()
            Menu("Scroll Diff") {
                ForEach([CommandID.pageDown, .pageUp, .halfPageDown, .halfPageUp, .scrollDown, .scrollUp], id: \.self) {
                    review($0).disabled(model?.canScrollDiff != true)
                }
                Divider()
                review(.scrollToTop).disabled(model?.canScrollDiff != true)
                review(.scrollToBottom).disabled(model?.canScrollDiff != true)
            }
        }

        CommandGroup(after: .help) {
            global(.showKeybindings)
        }
    }

    private func global(_ command: CommandID) -> some View {
        CommandButton(command) { _ = GlobalCommands.perform(command, openWindow: openWindow) }
    }

    private func review(_ command: CommandID, title: String? = nil) -> some View {
        CommandButton(command, title: title) { _ = model?.perform(command) }
            .disabled(model == nil)
    }
}
