import AppKit
import MaserCore
import SwiftUI

@main
struct MaserApp: App {
    init() {
        // When launched via `swift run` there is no app bundle; make it a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("Review Requests", id: "queue") {
            ReviewQueueView()
                .frame(minWidth: 600, minHeight: 400)
        }

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

        .commands { MaserCommands() }
    }
}
