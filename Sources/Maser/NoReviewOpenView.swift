// What the main window's detail column shows when no review is open.
//
// Usually a hint to pick a PR. When the queue's Review requested search has just succeeded and found nothing, it says
// so instead, with when the queue was checked, so an old result can be told from a fresh one. Whether that is true is
// decided by `QueueSection.reviewRequestStatus(in:)` in MaserCore; this view only words it.

import MaserCore
import SwiftUI

/// The detail column's placeholder: a hint to open a PR, or congratulations when no reviews are requested.
struct NoReviewOpenView: View {
    /// What the queue's last load knows about reviews requested of the viewer.
    let status: ReviewRequestStatus
    /// When the queue last loaded, if it has.
    let loadedAt: Date?

    /// The heading when nothing is known to be clear.
    static let noneOpenTitle = "No pull request open"
    /// The heading when the Review requested search succeeded and found nothing.
    static let clearTitle = "No reviews requested. Nice work!"

    var body: some View {
        if status == .clear, let loadedAt {
            let detail = "Checked \(Self.checked(loadedAt)). Open a pull request by URL with ⌘O."
            VStack(spacing: 12) {
                MaserMark()
                Text(Self.clearTitle)
                    .font(.title2.bold())
                    .shownText("no-review-open", Self.clearTitle)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .shownText("no-review-checked", detail)
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

    /// Words when the queue was checked: the time alone today, with the date for an earlier day.
    ///
    /// - Parameter date: When the queue last loaded.
    /// - Returns: Text such as "at 2:06 PM" or "on Nov 12, 2026 at 2:06 PM".
    private static func checked(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "at \(time)" }
        return "on \(date.formatted(date: .abbreviated, time: .omitted)) at \(time)"
    }
}
