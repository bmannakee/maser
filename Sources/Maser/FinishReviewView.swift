// The "Finish your review" sheet.
//
// Shown from a review window when the user submits their review. It collects an optional summary and a verdict, then
// publishes the pending review with its draft comments, or discards the pending review entirely.

import MaserCore
import SwiftUI

/// Submits the pending review (or a review with just a verdict), like github.com's "Finish your review".
///
/// The summary and verdict live on `ReviewModel`, so cancelling keeps them for next time. The model closes the sheet
/// after a successful submit or discard; on failure it stays open and shows the error.
struct FinishReviewView: View {
    @Bindable var model: ReviewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var summaryFocused: Bool
    /// Whether the "Discard your pending review?" confirmation is showing.
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Finish your review").font(.title3.bold())
                Text(pendingDescription).foregroundStyle(.secondary)
            }

            TextEditor(text: $model.reviewSummary)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            summaryFocused ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: summaryFocused ? 2 : 1)
                }
                .overlay(alignment: .topLeading) {
                    if model.reviewSummary.isEmpty {
                        Text("Leave a summary (optional, Markdown)")
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 11)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 120)
                .focused($summaryFocused)

            Picker("Verdict", selection: $model.reviewEvent) {
                ForEach(ReviewEvent.allCases) { event in
                    Text(event.title).tag(event)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if let error = model.reviewError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            HStack {
                if model.hasPendingReview {
                    Button("Discard Review…", role: .destructive) { confirmingDiscard = true }
                        .disabled(model.isSubmittingReview)
                }
                Spacer()
                if model.isSubmittingReview { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Submit Review") {
                    Task { await model.submitReview() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.isSubmittingReview || model.reviewNeedsSummary)
            }
            if model.reviewNeedsSummary {
                Text("With no draft comments, \(model.reviewEvent.title) needs a summary.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("⌘↩ submits · Esc cancels").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { summaryFocused = true }
        .confirmationDialog(
            "Discard your pending review?",
            isPresented: $confirmingDiscard
        ) {
            Button(
                "Discard \(model.pendingCommentCount) Draft Comment\(model.pendingCommentCount == 1 ? "" : "s")",
                role: .destructive
            ) {
                Task { await model.discardReview() }
            }
        } message: {
            Text("This deletes the pending review and its draft comments from GitHub.")
        }
    }

    /// The subtitle saying how many draft comments submitting will publish.
    private var pendingDescription: String {
        switch model.pendingCommentCount {
        case 0: "No draft comments. Submit a verdict or summary on its own."
        case 1: "1 draft comment will be published."
        case let count: "\(count) draft comments will be published."
        }
    }
}
