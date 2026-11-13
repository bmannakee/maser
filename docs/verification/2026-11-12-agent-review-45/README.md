# Verification record: the review agent asked for a review, 2026-11-12

The agent's second real review, of #45 (the file tree redraw, #44). Unlike the first
([2026-11-12-agent-first-review](../2026-11-12-agent-first-review/README.md)), the user asked it explicitly for a
thorough review, after a diagram. Nothing was planted this time, so this record says what it found, not how much it
missed.

- **Software:** Maser bundled from the `file-tree-redraw` branch at 64e06af, signed ad hoc. Claude Code 2.1.323,
  model claude-opus-5-5, default effort.
- **Performed by:** the user (the review in Maser). The conversation was read back from Maser's saved transcript and
  the comments from GitHub by Claude Code (agent), which checked each finding and wrote this record.
- **Cost:** $0.73 over two turns ($0.44 and $0.29).

## Summary

| # | Check | Result | Led to |
| --- | --- | --- | --- |
| V20 | An explicit review of a small PR | 4 comments, all on the docs and the test record; 4 correct, one with a wrong detail. No code defect found, and none known. It said what it hadn't checked. | All 4 fixed in #45 |
| V21 | Diagram refusals and flags on a flowchart | A node named `click` was refused, and an `edgeN` ID flagged; the agent corrected both | A note on #32: the tool description gives only state-diagram edge IDs |

## Details

### V20: The review

The first turn asked "show me what components this PR affects and how they relate to the rest of the app". The
agent traced every caller of `ReviewModel.select(path:)` and drew them. The second asked "can you review give this
code a thorough review please?". The agent read the risk file, the record and its contact sheets, and searched the
sources. Then it added four draft comments and summarized them, with what it had and hadn't checked: it didn't run
`scripts/check` or `check-ui`.

| Comment | Checked by Claude Code |
| --- | --- |
| The record says the tree "looks as before", but before the fix the selected row was usually regular weight, and now it's always semibold | Correct, from the contact sheets. Its added remark that the commit message says the same is wrong: the commit message makes no such claim. |
| HAZ-26's bullet in the risk file is out of order, after a stray blank line | Correct |
| REQ-DIF-010 promises the fix for keys, clicks and moves Maser makes, but only `[`/`]` were captured, and the Gap note leaves that out | Correct; the README's "Not checked" said so, the requirement didn't |
| The capture scenario passes with no images when the capture loop isn't running, and doesn't stop if `]` never reaches Keymap.swift | Correct. Fixed: it now fails with "nothing captured …; is capture-loop.sh running?", which a run without the loop showed, and a run with the loop still passed with 13 captures. |

Not found by the agent: the sentence after the residual-risk list said no risk "is waiting on a further control"
while HAZ-11 and HAZ-26 list candidate controls. Claude Code found it while fixing the second comment.

It also noted, without a comment, that every file row now re-renders on each selection change, which it judged
negligible and didn't measure.

### V21: Refusals and flags on a flowchart

- The first drawing was refused: "Diagrams can't use click". The agent had named a node `click`, so the line
  `click --> select` starts with `click `. Mermaid reads `click` as a keyword there, so refusing it is cautious, not
  wrong. The agent renamed the node.
- The second was shown with one flag: "edge7 isn't in the drawn diagram". Pele names flowchart edges `L_from_to_0`,
  not `edgeN`. The `show_diagram` description only mentions `edgeN`, which is right for state diagrams. Maser's reply
  listed the drawing's IDs, and the third drawing had no flags.
