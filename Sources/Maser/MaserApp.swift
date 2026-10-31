import AppKit
import SwiftUI

@main
struct MaserApp: App {
    init() {
        // When launched via `swift run` there is no app bundle; make it a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup("Maser") {
            ReviewQueueView()
                .frame(minWidth: 600, minHeight: 400)
        }
    }
}
