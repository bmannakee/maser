# Verification record: file tree selection redraw, 2026-11-12

Issue #44: in the first real review with the agent (#43), the file tree drew `GitHubCLI.swift` with its name
overprinted, bold over plain, and lightly highlighted, while another file was selected. It cleared when the review was
submitted. The diff pane doesn't name its file, so the tree's selection is the only sign of which file is shown
(HAZ-26).

- **Software:** Maser debug build from main at d2576ea, in the UI test bundle (`dev.maser.Maser.uitests`) against the
  fake `gh`; the fix as in this record's PR.
- **How:** the scenario in `capture-scenario.swift.txt` opens PR #16 (16 files), puts two pending agent comments on
  `Sources/MaserCore/Keymap.swift` while the Agent tab is showing, as when the agent posts them, then moves through the
  files with `[` six times and `]` six times. After each move it waits 0.8 s and asks for a capture of its window. The
  test app can't capture the screen itself, so `capture-loop.sh`, run from a shell with screen-recording permission,
  captures only that window. `before-fix.png` and `after-fix.png` put the file tree from the 13 captures side by side,
  in order, first row then second.
- **Performed by:** Claude Code (agent), at the user's request. Judged by eye.

## Summary

| # | Check | Result | Led to |
| --- | --- | --- | --- |
| V18 | The tree before the fix | Reproduced: after the selection leaves `FileTree.swift` (frame 2), its name stays bold in 11 of the 12 later frames. The selected row is bold in some frames and not others. | RC-32 |
| V19 | The tree after the fix | In all 13 frames, exactly one row is bold and highlighted: the selected one | REQ-DIF-010 met for this sequence |

## Details

### V18: Before

The first exploration (not kept) also walked Finish Review: pressing `S` with the agent's comments unopened, `⌘↩`,
then Esc on the question and Esc on the sheet. The cancelled question didn't cause the stale row, and opening the sheet
cleared it. Moving the selection is what causes it. It looks as if SwiftUI's list restyles a row it
selects, but doesn't always restyle the row it leaves, and nothing in the row's own content changed to force a redraw.
The bold seen in #44 is the selected style; the light highlight there, which these captures don't show, is likely the
same leftover from a different state of the row.

### V19: After

`FileRow` takes `isSelected` (the model's selected path equals the row's) and sets the name's weight from it, semibold
or regular. Moving the selection now changes both rows' content, so SwiftUI redraws both. This changes how the tree
looks: before, the selected row was regular weight in most frames and bold in a few; now it is always semibold. The
selection is now consistent, which is the point, but it is a visible change, not the same look minus the leftovers.
(Found in review by the agent, V-2026-11-12/V20.)

## Not checked

- Clicks, and selection moved by Maser itself (such as Return on a canvas citation). These go through the same
  `selectedPath`, so the same redraw applies, but weren't captured.
- The light highlight in #44, which didn't reproduce.
- An automated check. A scenario can't capture its own window, and drawing the views afresh (`cacheDisplay`) wouldn't
  show a leftover from an earlier drawing.
