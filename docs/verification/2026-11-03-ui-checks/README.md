# Verification record: UI checks, 2026-11-03

What was checked on screen, or in the running app, while building PRs #13, #15 and #16, and what each check showed.
These checks were ad hoc: written to chase a bug or confirm a fix, run once or a few times, then removed from the code.
This record keeps them so they can become repeatable tests (see "Follow-up").

- **Software:** Maser at `main` before and after PRs #13, #15 and #16. Builds from `scripts/bundle`, where the bundle
  version is the commit at build time.
- **Environment:** macOS 27.0.1, Xcode 27.1 / Swift 6.4, the home Mac. GitHub through `gh`, signed in as the user.
- **Performed by:** Claude Code (agent), with the user testing by hand and reporting results.
- **Limits:**
  - The terminal has no Screen Recording permission, so no screenshots were taken. Visual layout was judged by the user.
  - The scripted checks can't click the mouse.

## Summary

| # | Check | Method | Result | Led to |
| --- | --- | --- | --- | --- |
| V1 | Diff row height with and without gutter icons | Standalone probe | Pass (no change) | Ruled out one cause of #12 |
| V2 | Holding j/k scrolls smoothly | User, by hand | Pass after fix | PR #13 |
| V3 | `gh search prs` query handling | Live `gh`, `GH_DEBUG=api` | Behavior recorded | Query splitting in PR #15 |
| V4 | Queue searches against GitHub | Live tests (`MASER_LIVE_TESTS=1`) | Pass | PR #15 |
| V5 | Crash on quit, then on `g f` | Crash reports and `log show` | Cause found | PR #16 fixes |
| V6 | Nested split views crash | Standalone repro app | Reproduced; fix candidate passed | PR #16 (first fix, incomplete) |
| V7 | Files tab crash in the real app, bisected | In-app hook flipping tabs | Cause found; fix passed | PR #16 (final fix) |
| V8 | `c` keeps focus in the comment box | In-app scripted run, with and without `defaultFocus` | Cause confirmed; fix passed | PR #16 |
| V9 | ⌘0 gives the queue the keys | In-app scripted run | Bug reproduced | PR #16 |
| V10 | Key routing between the queue and the review | In-app scripted run | Pass after fixes | PR #16 |
| V11 | Window opening with nothing shown | User report, cause reasoned | Fixed, not re-run | PR #16 |

## Details

### V1: Diff row height with and without gutter icons

- **Question:** does the ＋ comment button on the cursor row make that row taller, shifting the diff on every
  keypress (a possible cause of the jitter in #12)?
- **Method:** `scripts/rowheight.swift` lays out one diff row three ways in an `NSHostingView` and prints its
  `fittingSize`: with an empty gutter, with the ＋ button, and with a thread marker.
- **Result:** every row was 17.0 pt, the same as the expected row height. The button doesn't change the row's height,
  so this cause was ruled out.

### V2: Holding j/k scrolls smoothly

- **Method:** the user held `j`/`k` in hunk and full-file modes, before and after PR #13.
- **Result:**
  - **Before:** slow and jittery.
  - **After:** "yes, that is better".
- The remaining speed limit is the system key repeat rate (`KeyRepeat` is unset, so the macOS default applies).

### V3: `gh search prs` query handling

Each finding was run against live GitHub. Where it matters, `GH_DEBUG=api` showed the query `gh` sends:

- **Whole query in one argument:** `gh` quotes it into a single phrase (`repo:"bmannakee/maser is:closed"`), and GitHub
  rejects it.
- **One word per argument after `--`:** works. Qualifiers apply, and `-label:x` isn't taken for a flag.
- **Arguments with a space:** `gh` quotes them itself (`label:help wanted` became `label:"help wanted"`). Passing
  quotes in as well double-escapes them.
- **`--state=open` with a `state:closed` qualifier:** returns nothing, so `is:open` is added only when the query
  doesn't pick a state.

### V4: Queue searches against GitHub

`MASER_LIVE_TESTS=1 swift test --filter 'LivePullRequestSearchTests|LiveGitHubTests'` passed. It covers:

- an `is:merged` search;
- every built-in search;
- a quoted phrase that finds exactly #10;
- the existing pagination test.

### V5: Crash on quit, then on `g f`

- **Method:** the crash reports were read from `~/Library/Logs/DiagnosticReports` (`Maser-*.ips`): the faulting
  thread and `lastExceptionBacktrace`. The exception reason came from `log show --predicate 'process == "Maser"'`.
- **Result:** every crash was the same AppKit exception: "The window has been marked as needing another Update
  Constraints in Window pass, but it has already had more Update Constraints in Window passes than there are views in
  the window", then `NSGenericException`.
- The first crash (18:36:17) was on quit, when the agent quit the app to restart it. The others (18:41, 18:45) happened
  on switching to the Files tab in the new main window.

### V6: Nested split views crash

- **Method:** `scripts/nested-split-repro.swift` is a standalone app with a `NavigationSplitView`. Its detail column
  switches every 0.4 s between a text view and a Files-like view, 12 times. It runs in two modes:
  - `nested`: a `NavigationSplitView` with an inspector, like the old Files tab;
  - `hsplit`: an `HSplitView` with an inspector.
- **Result:**
  - `nested` crashed with the V5 exception (exit 134).
  - `hsplit` survived.
- The fix based on this was incomplete: the real app still crashed (V7), because the repro left out something the real
  Files tab had.

### V7: Files tab crash in the real app, bisected

- **Method:**
  1. A temporary hook in `MainView` (the `DEBUG-REPRO` block, see `scripts/hook.py`) waits for the launch PR (#15) to
     load, then flips its tab between Overview and Files every second.
  2. `scripts/try.sh` runs the bundled app with the hook and one variant switch, then counts tab switches and whether
     it reached "survived".
  3. The variants replaced the Files tab's body. That code was temporary and has been removed.
- **Result** (`output-files-tab-bisect.txt`):

  | Variant | File tree | Diff | Comments as an inspector | Outcome |
  | --- | --- | --- | --- | --- |
  | Plain text instead of the tab | – | – | – | survived 10 switches |
  | No inspector | ✓ | ✓ | – | survived 10 |
  | No tree | – | ✓ | ✓ | survived 10 |
  | No diff | ✓ | – | ✓ | **crashed on the first switch** |
  | Three `HSplitView` panes, no inspector | ✓ | ✓ | as a pane | survived 10 |
  | Fixed-width tree in an `HStack`, with inspector | ✓ | ✓ | ✓ | survived 10 |
  | Final: three panes, with comments toggled in between | ✓ | ✓ | as a pane | survived 16 |

- **Conclusion:** the loop needs the resizable file tree and the inspector together, inside the main window's split
  view. The fix uses no inspector. The Files tab is now plain panes, with fixed widths after V8.

### V8: `c` keeps focus in the comment box

- **Reported:** `c` did nothing on the Overview tab. On Files, `c` opened the comment box, then focus jumped to the
  queue list.
- **Method:** a hook script did the following, logging the window's first responder and the queue's focus state at
  each step:
  1. Focus the queue list.
  2. Press `c` on Overview.
  3. Clear focus, then switch to Files.
  4. Press `j` three times, then `c`.
  5. Check again after 0.3 s and 2.3 s.
- **Result** (`output-focus-without-defaultFocus.txt`, `output-focus-with-defaultFocus.txt`):
  - **Without `.defaultFocus($focus, .list)`:** the first responder was `PlatformTextView`, the comment editor, after
    `c` on Overview and at both times on Files.
  - **With it put back:** the first responder was `SwiftUIOutlineListView`, the queue list, in all three cases.
  - So `defaultFocus` was the cause, and removing it is the fix.
- The run also read the split-view widths: the sidebar was 340 pt, a width restored from an earlier session.

### V9: ⌘0 gives the queue the keys

- **Method:** `scripts/script1-cmd0-focus.swift` does the following:
  1. Focuses the list.
  2. Opens the PR the way a click does.
  3. Calls `focusQueue()` (what ⌘0 does).
  4. Presses `j`.
- **Result:** after ⌘0, the focus state and the first responder both stayed `nil`, so `j` went to the review. Setting
  `FocusState` to the list didn't make the list first responder.
- **Fix:** the window now tracks who has the keys itself (`MainWindowState.queueHasKeys`) instead of reading focus.

### V10: Key routing between the queue and the review

- **Method:** `scripts/script2-key-routing.swift`, run by `scripts/runhook.sh` against the final build. The last run is
  in `output-key-routing.txt`.
- **Result:** every step matched the intended behavior:

| Step | Expected | Observed |
| --- | --- | --- |
| Start, PR #15 open | Review has the keys | `queueKeys=false` |
| `/` with the review holding the keys | Nothing happens | No change |
| ⌘0 | Queue has the keys, list focused, open PR selected | `queueKeys=true`, list first responder, `sel=[15]` |
| `j` on the last PR | Stays put | `sel=[15]` |
| `k` | Previous PR selected and shown; queue keeps the keys | `sel=[16]`, `open=16`, `queueKeys=true` |
| `j`, Return | PR opened; review has the keys | `open=15`, `queueKeys=false` |
| `e` (pane shown, review has the keys) | Pane hidden | `vis=hidden` |
| `e` again | Pane shown; queue has the keys | `vis=shown`, `queueKeys=true` |
| `e` a third time | Pane hidden; review has the keys | `vis=hidden`, `queueKeys=false` |
| `/` with the pane hidden | Nothing happens | No change |

- An earlier run of the same script, before `e` became a plain toggle, showed `e` handing over the keys instead of
  hiding the pane. That's what made the agent change it.
- `/` while the queue has the keys was checked in that earlier run: it focused the filter (`_SystemTextFieldFieldEditor`,
  `focus=filter`).

### V11: Window opening with nothing shown

- **Reported:** after the scripted runs, the user's window showed no PRs.
- **Cause:** the last scripted run ended with the sidebar hidden, and macOS restored it hidden. With no review open,
  the window was empty.
- **Fix:** the sidebar is always shown when no review is open. This was not re-run by script, and hasn't yet been
  confirmed on screen.

The scripts in `scripts/` are kept exactly as they ran. They have hard-coded paths to the agent's scratch directory and
patch `MainView.swift` temporarily, so they are a record, not tools to run again.

## Not checked

- Mouse clicks on queue rows (they open a PR and give it the keys), and ⌥Return opening a separate window. The user
  has done some of this by hand.
- Visual layout: pane widths, the open-PR marker, section headers, and the empty and error states.
- The Dock icon reopening a closed main window.
- Startup and focus timing after the move to one window.

## Follow-up

These checks are the seed for a scripted UI test harness run before every merge:

- **Replace the hand-edited hook with a built-in test driver.** For example, a debug-only `MASER_UI_SCRIPT` that runs
  named scenarios and asserts on app state.
- **Run the scenarios from `scripts/check`,** or from a separate `scripts/check-ui`.
- **Trace each scenario** to the requirements and risks it verifies.
