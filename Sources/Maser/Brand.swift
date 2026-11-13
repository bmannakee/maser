// maser's brand colors, as SwiftUI colors that follow the window's appearance.
//
// The values mirror the color table in `docs/design/brand.md`; change both together. Views use these instead of literal
// colors, so the light and dark values stay paired. Nothing here decides where a color is used: the brand document does.

import AppKit
import SwiftUI

extension Color {
    /// The brand palette: each color resolves to its light or dark value with the appearance it's drawn in.
    enum Brand {
        // MARK: - Ruby: where you are and what you're about to do

        /// The accent: the line cursor's rule, the primary button, the focus ring, the open PR's marker, links.
        static let ruby = Color(light: 0xC2255C, dark: 0xFF6B9A)
        /// Ruby text on `rubyWash`, such as the cursor line's number, and the primary button when pressed.
        static let rubyStrong = Color(light: 0xA01A48, dark: 0xFF9DBB)
        /// The fill of the cursor line and of selected rows.
        static let rubyWash = Color(light: 0xF9DCE7, dark: 0x4A1A2E)
        /// Text and icons on a `ruby` fill.
        static let onRuby = Color(light: 0xFFFFFF, dark: 0x2B0A16)

        // MARK: - Beam: pending, not yet posted

        /// The beam in the icon; in the app, the fill of the pending marker only.
        static let beam = Color(light: 0xFFC857, dark: 0xFFC857)
        /// Text and icons that mean pending or not yet posted.
        static let beamInk = Color(light: 0x8A5A00, dark: 0xFFC857)
        /// The background of a pending comment or an unsent draft.
        static let beamWash = Color(light: 0xFFF1D0, dark: 0x3D2E0A)
        /// The icon's ground, for brand surfaces such as an About window; not an app surface.
        static let rod = Color(light: 0x2B0A16, dark: 0x2B0A16)
        /// The rod in the icon: `ruby`'s light value in both appearances, for use on the `rod` ground only.
        static let iconRuby = Color(light: 0xC2255C, dark: 0xC2255C)

        // MARK: - Neutrals

        /// Primary text.
        static let ink = Color(light: 0x24171B, dark: 0xF1E9EB)
        /// Secondary text: metadata, captions, help.
        static let inkMuted = Color(light: 0x5C4A50, dark: 0xB5A6AB)
        /// Line numbers and the quietest labels.
        static let inkFaint = Color(light: 0x6E5F63, dark: 0xA8989D)
        /// The content background: the diff, the overview, editors.
        static let paper = Color(light: 0xFFFFFF, dark: 0x1D1517)
        /// Window chrome: the queue sidebar, toolbars, the key hint bar.
        static let chrome = Color(light: 0xFBF8F7, dark: 0x171012)
        /// Dividers and card outlines.
        static let hairline = Color(light: 0xE6DCDD, dark: 0x3A2A2F)
        /// The border of an unfocused text field or secondary button.
        static let controlBorder = Color(light: 0x948489, dark: 0x7D6B71)

        // MARK: - Diff and status

        /// The background of an added line.
        static let addWash = Color(light: 0xE3F4E6, dark: 0x17301F)
        /// The `+` sign and added-line counts; also success.
        static let addInk = Color(light: 0x17722F, dark: 0x56D364)
        /// The background of a deleted line, orange-leaning so it stays apart from `rubyWash`.
        static let delWash = Color(light: 0xFCE9DD, dark: 0x3B2114)
        /// The `-` sign and deleted-line counts; also errors and refusals.
        static let delInk = Color(light: 0xB3400E, dark: 0xFF9A62)
    }

    /// Creates a color that follows the appearance.
    ///
    /// - Parameters:
    ///   - light: The `0xRRGGBB` value in light appearances.
    ///   - dark: The `0xRRGGBB` value in dark appearances.
    fileprivate init(light: UInt32, dark: UInt32) {
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(rgb: isDark ? dark : light)
            })
    }
}

extension NSColor {
    /// Creates an opaque sRGB color.
    ///
    /// - Parameter rgb: The color as `0xRRGGBB`.
    fileprivate convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
