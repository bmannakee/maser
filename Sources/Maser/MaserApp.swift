// The app's entry point and its windows.
//
// `MaserApp` declares the scenes: the review queue, one window per pull request, and the Open Pull Request and
// Keyboard Shortcuts windows. At launch it starts the config watcher and the vim-style key router that all windows share.

import AppKit
import MaserCore
import SwiftUI

/// The Maser app: a queue of pull requests awaiting review, and a review window for each one opened.
@main
struct MaserApp: App {
    /// Makes the process a regular foreground app, then starts loading the config and routing vim-style keys.
    init() {
        // When launched via `swift run` there is no app bundle; make it a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()

        ConfigStore.shared.start()
        KeyRouter.shared.start()
    }

    var body: some Scene {
        WindowGroup("Review Requests", id: "queue") {
            ReviewQueueView()
                .frame(minWidth: 600, minHeight: 400)
        }
        .commands { MaserCommands() }

        // One window per pull request; opening a PR that already has a window brings that window forward.
        WindowGroup("Pull Request", for: PullRequest.self) { $pr in
            if let pr {
                ReviewView(pr: pr)
                    .frame(minWidth: 900, minHeight: 500)
            } else {
                ContentUnavailableView("No pull request", systemImage: "arrow.triangle.pull")
            }
        }
        .defaultSize(width: 1500, height: 950)

        Window("Open Pull Request", id: OpenPullRequestView.windowID) {
            OpenPullRequestView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Keyboard Shortcuts", id: KeybindingsView.windowID) {
            KeybindingsView()
        }
        .defaultSize(width: 640, height: 480)
    }
}
