// maser's mark, drawn in SwiftUI.
//
// The app icon as a small tile: the ruby rod with the amber beam leaving it, on the icon's dark ground, in the
// proportions of `Assets/icon/maser-icon.svg`. The rod and beam need that ground: alone on a window's background they
// lose the contrast the icon has. Drawn from `Color.Brand` rather than loaded from a file, so it needs no resource in
// the bundle. The brand document (`docs/design/brand.md`) says where the mark may appear.

import SwiftUI

/// maser's mark: the icon's tile, with the ruby rod and the amber beam leaving it to the right.
///
/// It looks the same in light and dark appearances, as the icon does.
struct MaserMark: View {
    /// The tile's width and height in points.
    var size: CGFloat = 72

    var body: some View {
        // The icon's 200-unit grid: a 100 by 48 rod 38 in from the leading edge, and a beam 10 tall from 58 in.
        let unit = size / 200
        ZStack(alignment: .leading) {
            Color.Brand.rod
            Capsule()
                .fill(Color.Brand.iconRuby)
                .frame(width: 100 * unit, height: 48 * unit)
                .padding(.leading, 38 * unit)
            // Longer than the tile is wide, so the tile's edge cuts the beam off square, as in the icon.
            Capsule()
                .fill(Color.Brand.beam)
                .frame(width: 160 * unit, height: 10 * unit)
                .padding(.leading, 58 * unit)
        }
        .frame(width: size, height: size, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 46 * unit, style: .continuous))
        // A faint edge, so the dark tile doesn't merge into a dark window.
        .overlay(RoundedRectangle(cornerRadius: 46 * unit, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
        // Decoration: the text beside it says everything.
        .accessibilityHidden(true)
    }
}
