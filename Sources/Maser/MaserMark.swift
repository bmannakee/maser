// maser's mark, drawn in SwiftUI.
//
// The ruby rod with the amber beam leaving it, in the proportions of `Assets/icon/maser-mark.svg`. Drawn from
// `Color.Brand` rather than loaded from a file, so it follows the appearance and needs no resource in the bundle. The
// brand document (`docs/design/brand.md`) says where the mark may appear.

import SwiftUI

/// maser's mark: the ruby rod with the amber beam leaving it to the right.
struct MaserMark: View {
    /// The rod's height in points; the mark is 3⅓ times as wide.
    var height: CGFloat = 36

    var body: some View {
        // The SVG's units: a 100 by 48 rod, and a 140 by 10 beam that starts 20 in from the rod's leading edge.
        let unit = height / 48
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.Brand.ruby)
                .frame(width: 100 * unit, height: height)
            Capsule()
                .fill(Color.Brand.beam)
                .frame(width: 140 * unit, height: 10 * unit)
                .padding(.leading, 20 * unit)
        }
        .frame(width: 160 * unit, height: height, alignment: .leading)
        // Decoration: the text beside it says everything.
        .accessibilityHidden(true)
    }
}
