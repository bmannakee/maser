// The app's entry point and its windows.
//
// `MaserApp` declares the scenes: the main window (the queue beside the open review), a window per pull request opened
// on its own, and the Open Pull Request and Keyboard Shortcuts windows. At launch it starts the config watcher and the vim-style key router that all windows share,
// and brings the app to the front once launching has finished.

import AppKit
import MaserCore
import SwiftUI

/// The Maser app: a queue of pull requests in a sidebar, with the selected one's review beside it.
@main
struct MaserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Makes the process a regular foreground app, then starts loading the config and routing vim-style keys.
    init() {
        // When launched via `swift run` there is no app bundle; make it a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)

        ConfigStore.shared.start()
        KeyRouter.shared.start()
    }

    var body: some Scene {
        WindowGroup("Pull Requests", id: MainView.windowID) {
            MainView()
                .frame(minWidth: 900, minHeight: 500)
        }
        .defaultSize(width: 1600, height: 950)
        .commands { MaserCommands() }

        // A PR opened in a window of its own; opening one that already has a window brings that window forward.
        WindowGroup("Pull Request", for: PullRequest.self) { $pr in
            if let pr {
                ReviewWindow(pr: pr)
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

/// Handles app lifecycle events that SwiftUI's `App` doesn't expose.
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Asking to activate before launch finishes can be ignored, which left the app open but in the background.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate()
    }
}
