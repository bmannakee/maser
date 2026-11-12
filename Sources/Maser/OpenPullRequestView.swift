// The Open Pull Request window.
//
// A small window, reachable from any window through the `openPullRequest` command, that takes a GitHub PR URL, looks
// the PR up with `gh`, and shows its review in the main window.

import AppKit
import MaserCore
import SwiftUI

/// Small window that takes a PR URL, prefilled from the clipboard, and opens it for review.
///
/// The window closes once the PR loads; if loading fails, the error from `gh` shows under the field.
struct OpenPullRequestView: View {
    /// The scene ID used to open and dismiss this window.
    static let windowID = "open-pull-request"

    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    /// The URL field's contents.
    @State private var text = ""
    /// Whether a PR lookup is in progress.
    @State private var isLoading = false
    /// Why the last lookup failed, shown under the field.
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Pull Request").font(.headline)
            TextField("https://github.com/owner/repo/pull/123", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .onSubmit(open)
            if let error {
                Text(error).font(.caption).foregroundStyle(Color.Brand.delInk)
            }
            HStack {
                if isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismissWindow(id: Self.windowID) }
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: open)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading || url == nil)
            }
        }
        .padding()
        .commandHandler { _ in false }  // App-wide keys still work when the field isn't focused.
        .onAppear {
            // The window can be reused, so start fresh each time it opens.
            text = ""
            error = nil
            if let clip = NSPasteboard.general.string(forType: .string),
                let clipURL = URL(string: clip.trimmingCharacters(in: .whitespacesAndNewlines)),
                PullRequest.nameWithOwner(fromURL: clipURL) != nil
            {
                text = clipURL.absoluteString
            }
        }
    }

    /// The typed URL, or `nil` unless it looks like a GitHub pull request URL.
    private var url: URL? {
        URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            PullRequest.nameWithOwner(fromURL: $0) != nil ? $0 : nil
        }
    }

    /// Looks up the PR and shows it in the main window, closing this one on success.
    private func open() {
        guard let url else { return }
        isLoading = true
        error = nil
        Task {
            defer { isLoading = false }
            do {
                let pr = try await GitHubCLI().pullRequest(url: url)
                dismissWindow(id: Self.windowID)
                MainWindows.shared.show(pr, openWindow: openWindow)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
