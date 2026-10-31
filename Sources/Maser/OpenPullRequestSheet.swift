import AppKit
import MaserCore
import SwiftUI

/// Prompts for a PR URL (prefilled from the clipboard when it holds one) and opens it for review.
struct OpenPullRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var text = ""
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Pull Request").font(.headline)
            TextField("https://github.com/owner/repo/pull/123", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 420)
                .onSubmit(open)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                if isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: open)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isLoading || url == nil)
            }
        }
        .padding()
        .onAppear {
            if let clip = NSPasteboard.general.string(forType: .string),
               let clipURL = URL(string: clip.trimmingCharacters(in: .whitespacesAndNewlines)),
               PullRequest.nameWithOwner(fromURL: clipURL) != nil {
                text = clipURL.absoluteString
            }
        }
    }

    private var url: URL? {
        URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            PullRequest.nameWithOwner(fromURL: $0) != nil ? $0 : nil
        }
    }

    private func open() {
        guard let url else { return }
        isLoading = true
        error = nil
        Task {
            defer { isLoading = false }
            do {
                let pr = try await GitHubCLI().pullRequest(url: url)
                openWindow(value: pr)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
