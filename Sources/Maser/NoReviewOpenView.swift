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
    static let clearTitle = "No reviews requested. Nice work!"

    var body: some View {
        if status == .clear {
            VStack(spacing: 24) {
                MaserMark(height: 72)
                Text(Self.clearTitle)
                    .font(.system(size: 34, weight: .bold))
                    .shownText("no-review-open", Self.clearTitle)
            }
            .multilineTextAlignment(.center)
            .padding()
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
