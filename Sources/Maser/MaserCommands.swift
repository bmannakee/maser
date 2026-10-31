import AppKit
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

/// Menu bar commands. Shortcuts come from `Keymap`.
struct MaserCommands: Commands {
    @FocusedValue(\.reviewModel) private var model
    @FocusedValue(\.refreshAction) private var refresh
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Pull Request…") { openWindow(id: OpenPullRequestView.windowID) }
                .keyboardShortcut(.openPullRequest)
        }

        CommandGroup(before: .toolbar) {
            ForEach(ReviewModel.Tab.allCases) { tab in
                Button(tab.title) { model?.tab = tab }
                    .keyboardShortcut(tab.command)
                    .disabled(model == nil)
            }
            Button(model?.showComments == true ? "Hide Comments" : "Show Comments") {
                model?.showComments.toggle()
            }
            .keyboardShortcut(.toggleComments)
            .disabled(model?.tab != .files)
            Divider()
        }

        CommandMenu("Review") {
            Button("Refresh") { refresh?.perform() }
                .keyboardShortcut(.refresh)
                .disabled(refresh == nil)
            Button("Open on GitHub") {
                if let url = model?.pr.url { NSWorkspace.shared.open(url) }
            }
            .keyboardShortcut(.openOnGitHub)
            .disabled(model == nil)

            Divider()

            Button("Next File") { model?.selectAdjacentFile(offset: 1) }
                .keyboardShortcut(.nextFile)
                .disabled(model == nil)
            Button("Previous File") { model?.selectAdjacentFile(offset: -1) }
                .keyboardShortcut(.previousFile)
                .disabled(model == nil)

            Divider()

            Button("Next Comment Thread") { model?.focusAdjacentThread(offset: 1) }
                .keyboardShortcut(.nextThread)
                .disabled(model == nil)
            Button("Previous Comment Thread") { model?.focusAdjacentThread(offset: -1) }
                .keyboardShortcut(.previousThread)
                .disabled(model == nil)
        }
    }
}
