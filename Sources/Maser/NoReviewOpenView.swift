// What the main window's detail column shows when no review is open.
//
// Usually a hint to pick a PR. When the queue's Review requested search has just succeeded and found nothing, it says
// so instead, large and with nothing else. Whether that is true is decided by
// `QueueSection.reviewRequestStatus(in:)` in MaserCore; this view only words it.

import MaserCore
import SwiftUI

/// The detail column's placeholder: a hint to open a PR, or congratulations when no reviews are requested.
struct NoReviewOpenView: View {
    /// What the queue's last load knows about reviews requested of the viewer.
    let status: ReviewRequestStatus

    /// The heading when nothing is known to be clear.
    static let noneOpenTitle = "No pull request open"
    /// The heading when the Review requested search succeeded and found nothing.
    static let clearTitle = clearStatement + " " + clearPraise
    /// The fact in the congratulation, in the primary text color.
    private static let clearStatement = "No reviews requested."
    /// The praise that follows it, in the muted text color.
    private static let clearPraise = "Nice work!"

    var body: some View {
        if status == .clear {
            // Quiet on purpose: the mark at a modest size, one line in regular weight, and nothing else. It sits a
            // little above the middle, where a centered block looks centered.
            VStack(spacing: 24) {
                MaserMark(height: 40)
                (Text(Self.clearStatement).foregroundStyle(Color.Brand.ink)
                    + Text(" " + Self.clearPraise).foregroundStyle(Color.Brand.inkMuted))
                    .font(.system(size: 28, weight: .regular))
                    .shownText("no-review-open", Self.clearTitle)
            }
            .multilineTextAlignment(.center)
            .padding(24)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                Self.noneOpenTitle, systemImage: "arrow.triangle.pull",
                description: Text("Pick one from the list, or open one by URL with ⌘O.")
            )
            .shownText("no-review-open", Self.noneOpenTitle)
        }
    }
}
