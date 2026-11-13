# Brand

maser's name, logo and colors, and how the interface uses them. Draft 1, 2026-11-12. Direction: Ruby.

The browsable version, with live previews, is the "maser brand" design system artifact. This file is the copy that
travels with the code; `Sources/Maser/Brand.swift` mirrors its color table.

**Status:** the icon is in the app bundle (REQ-PLT-004). The views take the accent, the pending amber, the diff washes
and the error and success colors from `Brand.swift`, and each window is tinted ruby. Still on system colors: text and
backgrounds (`ink`, `paper`, `chrome` are defined but unused), the PR state pill, warnings, and the notices with a
yellow background.

## The idea

A maser amplifies one frequency into a single coherent beam. Reviewing is the same act: out of a whole diff, you attend
to one line at a time.

- **The rod** is the ruby crystal of a solid-state maser: the body of the logo, and the accent color.
- **The beam** is the amplified line leaving the rod: amber in the logo, and the line cursor in the app.

Everything else is quiet, so the beam is the brightest thing on screen.

## Name and voice

- Write the name **maser**, lowercase, wherever a person reads it, including at the start of a sentence.
- Identifiers keep their conventions: `Maser.app`, the `Maser` and `MaserCore` targets, `dev.maser.Maser`.
- Messages are short, specific sentences that say what happened and what to do, naming the key, the account and the PR.
  No exclamation marks, with one exception: the congratulation when no reviews are requested (REQ-QUE-008).

## Logo

| Form | File | Use |
| --- | --- | --- |
| App icon | `Assets/AppIcon.icns`, from `Assets/icon/maser-icon.svg` | The Dock, Finder, the app switcher. |
| Small icon | `Assets/icon/maser-icon-small.svg`, `maser-icon-medium.svg` | The 16 and 32 px, and 64 px, renderings: larger rod, thicker beam. |
| Mark | `Assets/icon/maser-mark.svg`, `-on-dark`, `-ink` | The rod and beam without the ground: README, docs. |
| Wordmark | Live type | "maser" in Bricolage Grotesque Bold, lowercase, letter-spacing -0.03em. |

- The beam always points right and always leaves the rod. Don't rotate, mirror, outline or recolor the mark.
- Clear space is half the mark's height on every side. Below 64 px, use the small icon.
- In the app, the mark is drawn by `MaserMark` (`Sources/Maser/MaserMark.swift`) as the icon's tile: the rod and beam
  on the `rod` ground, the same in both appearances. The rod and beam alone get lost on a window's background, so
  inside the app they always sit on that ground. It appears in one place: above the congratulation when no reviews
  are requested.
- To rebuild the icon after changing an SVG, render each size to PNG and pack them into `Assets/AppIcon.icns`
  (`iconutil -c icns` on an `.iconset` folder).

## Color

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `ruby` | `#C2255C` | `#FF6B9A` | The accent: cursor bar, primary button, focus ring, open-PR marker, links. |
| `rubyStrong` | `#A01A48` | `#FF9DBB` | Ruby text on `rubyWash`: the cursor line's number. |
| `rubyWash` | `#F9DCE7` | `#4A1A2E` | Fill of the cursor line and selected rows. |
| `onRuby` | `#FFFFFF` | `#2B0A16` | Text on a `ruby` fill. |
| `beam` | `#FFC857` | `#FFC857` | The icon's beam; the pending marker's fill. |
| `beamInk` | `#8A5A00` | `#FFC857` | Text that means pending or not yet posted. |
| `beamWash` | `#FFF1D0` | `#3D2E0A` | Background of a pending comment or unsent draft. |
| `rod` | `#2B0A16` | `#2B0A16` | The icon's ground. Brand surfaces only. |
| `iconRuby` | `#C2255C` | `#C2255C` | The rod in the icon and the in-app mark, on `rod` only. |
| `ink` | `#24171B` | `#F1E9EB` | Primary text. |
| `inkMuted` | `#5C4A50` | `#B5A6AB` | Secondary text. |
| `inkFaint` | `#6E5F63` | `#A8989D` | Line numbers. |
| `paper` | `#FFFFFF` | `#1D1517` | Content background. |
| `chrome` | `#FBF8F7` | `#171012` | Sidebar, toolbars, key hint bar. |
| `hairline` | `#E6DCDD` | `#3A2A2F` | Dividers. |
| `controlBorder` | `#948489` | `#7D6B71` | Border of a field or secondary button. |
| `addWash` | `#E3F4E6` | `#17301F` | Added line. |
| `addInk` | `#17722F` | `#56D364` | `+` sign; success. |
| `delWash` | `#FCE9DD` | `#3B2114` | Deleted line. |
| `delInk` | `#B3400E` | `#FF9A62` | `-` sign; errors and refusals. |

Text pairs were checked against WCAG 2 contrast: every text token is at least 4.5:1 on `paper`, `chrome` and the wash
it is meant for, in both themes. `ruby` on `rubyWash` is 4.4:1 in the light theme, so text on the wash is `rubyStrong`
or `ink`; `controlBorder` is 3.5:1, enough for a control boundary.

### Rules

- **The ruby budget.** In a window, ruby appears only on the line cursor, the one primary action, the focus ring, the
  open PR's marker and selected rows, and links. Anything else is `ink` or `inkMuted`.
- **Amber means pending.** `beamInk` and `beamWash` mark text that exists only on this Mac: line comments in a pending
  review, unsent drafts, a conversation about an older commit. Posted content is never amber.
- **Diff colors keep their meaning.** Deletions are orange-red, shifted away from ruby. Added and deleted lines keep
  their sign under the cursor, and the cursor keeps its rule, so no state depends on hue alone.
- **Agent output is neutral:** `ink` on `paper`, labeled as the agent's. Never ruby.
- **GitHub's colors stay GitHub's:** label colors, the PR state pill and the rendered conversation are shown as given.
- **The line cursor** is a 3 pt `ruby` bar at the line's leading edge with a ruby tint over the line. The tint lies
  over the line's own wash, so an added or deleted line under the cursor still reads as one.
- **Warnings have no token yet.** Blocked, behind, review required, checks pending, renamed files and the unsourced
  diagram note use the system orange. Open question: system orange sits close to the pending amber, so either
  warnings need their own hue or the two meanings need different shapes.

## Type, spacing and shape

- The app uses the system font and system monospaced font through SwiftUI text styles. Body is 13 pt, metadata is
  `.callout` in `inkMuted`, code is 12 pt monospaced. Bricolage Grotesque appears only in the wordmark.
- Spacing steps are 4, 8, 12, 16 and 24 pt. Panes and sheets pad by 16, cards by 12.
- Corners are 4 pt for badges and key caps, 8 pt for fields and comment boxes, 12 pt for cards and sheets.
- Dividers are `hairline`. maser adds no shadows and no animation of its own.

## Interface guidelines

- Every action is a command with a key; show the key beside the action where there is room.
- The pane that has the keys shows the ruby cursor or focus ring; the other pane shows neither.
- One primary action per view, filled ruby, whose label names the consequence ("Comment as @you").
- Destructive actions are a secondary button with a `delInk` label, never a filled red button.
- Use the tokens, which carry both appearances; no literal colors in views.
- Respect Increase Contrast, Reduce Motion and the user's text size.
