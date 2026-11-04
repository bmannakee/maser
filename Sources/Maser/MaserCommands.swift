// The app's menu bar.
//
// `MaserCommands` builds the View, Review and Help menu items from `CommandID`s, so their titles and shortcuts follow the
// user's config. Review commands go to the focused window's `ReviewModel` through focused values; app-wide ones go to
// `GlobalCommands`.

import AppKit
import MaserCore
import SwiftUI

extension FocusedValues {
    /// The model of the review window that has focus, if any.
    @Entry var reviewModel: ReviewModel?
    /// Reloads whatever the focused window shows.
    @Entry var refreshAction: RefreshAction?
    /// Focuses the review queue's filter box, when a queue window has focus.
    @Entry var filterAction: FilterAction?
}

/// A focused window's way to reload its content, published so the Refresh menu item can reach it.
struct RefreshAction {
    let perform: @MainActor () -> Void
}

/// A queue window's way to focus its filter box, published so the Filter menu item can reach it.
struct FilterAction {
    let perform: @MainActor () -> Void
}

/// The app's menu bar commands, with titles and shortcuts from `CommandID` and the user's config.
///
/// Review items are disabled when no review window has focus; Refresh works for any window that publishes a
/// `RefreshAction`.
struct MaserCommands: Commands {
    @FocusedValue(\.reviewModel) private var model
    @FocusedValue(\.refreshAction) private var refresh
    @FocusedValue(\.filterAction) private var filter
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            global(.openConfig)
        }

        CommandGroup(after: .newItem) {
            global(.openPullRequest)
        }

        CommandGroup(before: .windowList) {
            global(.showPullRequests)
            Divider()
        }

        CommandGroup(after: .textEditing) {
            CommandButton(.filter) { filter?.perform() }
                .disabled(filter == nil)
        }

        CommandGroup(before: .toolbar) {
            ForEach(ReviewModel.Tab.allCases) { tab in
                review(tab.command)
            }
            review(.toggleComments, title: model?.showComments == true ? "Hide Comments" : "Show Comments")
                .disabled(model?.tab != .files)
            Divider()
            review(.toggleFullFile, title: showsFullFile ? "Show Only This File's Changes" : "Show Full File")
                .disabled(model?.canScrollDiff != true)
            review(.expandAllFiles).disabled(model?.canScrollDiff != true)
            review(.collapseAllFiles).disabled(model?.canScrollDiff != true)
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

    /// Whether the focused window's selected file is set to show in full.
    private var showsFullFile: Bool {
        guard let model, let path = model.selectedPath else { return false }
        return model.wantsFullFile(path)
    }

    /// A menu item for an app-wide command, always enabled.
    private func global(_ command: CommandID) -> some View {
        CommandButton(command) { _ = GlobalCommands.perform(command, openWindow: openWindow) }
    }

    /// A menu item that sends a command to the focused review window, disabled when there isn't one.
    ///
    /// - Parameters:
    ///   - command: The command to send to `ReviewModel.perform(_:)`.
    ///   - title: A title to use instead of the command's own.
    /// - Returns: The menu item.
    private func review(_ command: CommandID, title: String? = nil) -> some View {
        CommandButton(command, title: title) { _ = model?.perform(command) }
            .disabled(model == nil)
    }
}
