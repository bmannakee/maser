# Verification record: the Files tab's file filter, 2026-11-25

What was checked on `/` narrowing the file tree by path (REQ-DIF-014, HAZ-31, RC-40, #74).

- **Software:** branch `filter-files`, from main at `bf2fb82`.
- **Environment:** a Mac with macOS 27.0.1 and Xcode 27.1. Not macOS 26.
- **How:** `scripts/check`, then `scripts/check-ui`.
- **Performed by:** Claude Code (agent), at the user's request.

## Summary

| # | Check | Result | Led to |
| --- | --- | --- | --- |
| V1 | The matching rule | Words in any order, ignoring case and accents, every word required, the order of the paths kept; an empty or blank filter keeps every path. | REQ-DIF-014 |
| V2 | The UI scenario `file-filter` | On the recorded PR with 16 files, `/` showed the box; typing a word narrowed the tree to the files that match, the count read "12 of 16", and the selected file was one that matched; the agent's file list still held all 16; after Return, `]` and `[` pressed past the ends stopped at the last and first match; Esc cleared the filter and hid the box. | REQ-DIF-014 |
| V3 | Whether V2 can fail | With `]`/`[` made to walk every file, not the filtered ones, the scenario failed ("] stops at the last match"). The first version of the scenario passed under that change, because the word it picked matched the first files; it now picks a word whose matches stop short of the PR's last file. | REQ-DIF-014 |
| V4 | The whole UI suite | 30 passed. | REQ-DIF-014 |

## Not checked

- **How it looks.** Nobody looked at the box, the count's color or the tree's width while filtering. The width is kept at
  least 220 pt while the box shows, so the box is usable.
- **A click on a row while filtered**, and the 100-file case at real size (the scenario's PR has 16).
- **Next/previous thread across hidden files**, which the code takes from the whole list (reasoning, not a scenario).
- **Reloading a filtered PR**, where the filter is kept by design.
- **macOS 26.**

## Details

### V2 and V3

`file-filter` takes the first word, from the path components of the PR's files, that matches at least two files, not all,
and not ending at the PR's last file. It types it after `/`, and reads the model's state and the shown count text.
Pressing the keys goes through the real key router.
