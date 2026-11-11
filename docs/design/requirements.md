# Software requirements

Modeled on IEC 62304 §5.2. Draft 1, 2026-11-03, covering `main` as of PR #16.

Each requirement lists:

- **Need:** the user need it serves.
- **Control:** the risk control it implements, if any.
- **Verified by:** how it's verified. **Gap** means it has no repeatable verification yet; most gaps are planned UI
  scenarios.
- **Status:**
  - `Implemented`: built and in `main`.
  - `Proposed`: a risk control not built yet. It has an issue, and its hazard's residual risk depends on it.

Reference forms are explained in [README.md](README.md#identifiers).

## GitHub access (GH)

| ID | Requirement | Need | Control | Verified by | Status |
| --- | --- | --- | --- | --- | --- |
| REQ-GH-001 | Maser reads and writes GitHub only by running the user's `gh` client. It never reads, stores, logs or transmits a GitHub token. | UN-8 | RC-11 | I: all GitHub calls go through `GitHubCLI.run` (rule in `AGENTS.md`); no code handles tokens. | Implemented |
| REQ-GH-002 | Maser finds `gh` in this order: the `[github] gh` setting, then the usual install locations (Homebrew, MacPorts, Nix, `~/.local/bin`, mise and asdf shims), then the user's login shell. The login-shell lookup gives up after 5 s. If `gh` isn't found, every window says so and how to set the path. | UN-7 | RC-13 | T:SettingsTests.readsSettings (the setting only). **Gap:** the search order and the not-found message. | Implemented |
| REQ-GH-003 | Lists that GitHub returns in pages are fetched in full: conversation comments, reviews, checks, labels, review requests, and the comments in a review thread. | UN-2, UN-3 | RC-02 | T:PullRequestOverviewTests.marksTruncatedLists, .replacesListsWithAllPages, .pagedQueriesPaginate; T:ReviewThreadTests.longThreadsGetTheirRemainingComments; L:LiveGitHubTests.paginatesLongLists | Implemented |
| REQ-GH-004 | Unexpected GitHub data never crashes Maser. Missing optional fields decode as absent, unknown enum values fall back to a default, and a failed request becomes a message in the window. | UN-2 | RC-14 | T:PullRequestOverviewTests.unknownEnumValuesDontBreakDecoding, .missingPullRequestThrows; T:ReviewThreadTests.emptyOutput; T:PullRequestTests.decodesEmptyResult; UI:post-comment (a failed post shows gh's message) | Implemented |
| REQ-GH-005 | Waiting on `gh` never blocks the user interface. | UN-10 | RC-15 | I: subprocesses run in `@concurrent` functions through the non-blocking `Subprocess` runner. **Gap:** no test. | Implemented |
| REQ-GH-006 | A PR on a GitHub Enterprise host is read from, and written to, that host. | UN-7 | — | T:PullRequestTests.nameWithOwnerFromURL (parsing only). **Gap:** no request made against a non-github.com host. | Implemented |

## Queue (QUE)

| ID | Requirement | Need | Control | Verified by | Status |
| --- | --- | --- | --- | --- | --- |
| REQ-QUE-001 | The queue shows these sections, in order: Review requested (`review-requested:@me`), Yours (`author:@me`), Involving you (`involves:@me`), then each search in `[queue] searches`. `[queue] sections` picks and orders the built-in sections. A search shows open PRs unless its query picks a state. | UN-1 | — | T:PullRequestSearchTests.ghArguments, .splitsQueryIntoWords; T:PullRequestTests.decodesGhSearchOutput; T:SettingsTests.readsQueue, .queueSectionsDefault; L:LivePullRequestSearchTests.searches | Implemented |
| REQ-QUE-002 | A PR appears only in the first section that finds it. Sections with no PRs and no error are hidden. Each section lists its PRs most recently updated first. | UN-1 | — | T:PullRequestSearchTests.displayedDeduplicates | Implemented |
| REQ-QUE-003 | The filter narrows the queue to PRs where every word matches the title, the repository, the author, or the number (`#123` matches exactly). | UN-1 | — | T:PullRequestSearchTests.filters | Implemented |
| REQ-QUE-004 | A search that fails shows its error in its own section and keeps its last results. The other sections still update. | UN-1 | RC-14 | T:PullRequestSearchTests.displayedDeduplicates (an error section is kept); UI:queue-search-fails. | Implemented |
| REQ-QUE-005 | A new main window shows the last results at once, and refetches only if they're over 60 s old. Changing the searches in config reloads at once. | UN-10 | — | **Gap:** UI:queue-cache. | Implemented |
| REQ-QUE-006 | When every section is empty, the queue says which searches it ran and how to add more. | UN-1 | — | **Gap:** UI:queue-empty. | Implemented |
| REQ-QUE-007 | While the queue has the keys, `j`/`k` move the selection, `]`/`[` jump to the first PR of the next or previous section (skipping empty ones), `g g`/`G` go to the first and last PR, `o` opens the selection on GitHub, and Return opens it. | UN-1, UN-5 | — | T:PullRequestSearchTests.sectionStarts; UI:queue-keys; V-2026-11-03/V10. **Gap:** `o` (it opens a browser). | Implemented |

## Main window (WIN)

| ID | Requirement | Need | Control | Verified by | Status |
| --- | --- | --- | --- | --- | --- |
| REQ-WIN-001 | The main window shows the queue in a sidebar and the open PR's review beside it. Each PR opened in the window keeps its state: tab, file, cursor and drafts. Going back to one refreshes it only if its data is over 60 s old. | UN-1, UN-10 | RC-17 | UI:switch-prs-keeps-state. | Implemented |
| REQ-WIN-002 | The sidebar marks the PR whose review is showing, which may not be the selected one. | UN-5, UN-8 | RC-06 | **Gap:** UI:open-pr-marker (state); visual check by the user. | Implemented |
| REQ-WIN-003 | Clicking a PR, or pressing Return on it, shows its review and gives the review the keys. The queue gets the keys back only from ⌘0, `g p`, `e`, or the filter box. Moving through the queue with `j`/`k` shows each PR without leaving the queue. | UN-5 | RC-06 | UI:key-routing; V-2026-11-03/V10. **Gap:** mouse clicks (U: the user, partly). | Implemented |
| REQ-WIN-004 | ⌥Return, or Open in New Window in the context menu, opens a PR in a window of its own. | UN-4 | — | **Gap:** UI:open-in-new-window. | Implemented |
| REQ-WIN-005 | ⌘O opens any PR by URL in the main window, and opens a main window if none is open. | UN-1 | — | **Gap:** UI:open-by-url. | Implemented |
| REQ-WIN-006 | A main window with no review open always shows the queue. | UN-1 | — | V-2026-11-03/V11 (cause only, not re-run). **Gap:** UI:empty-window-shows-queue. | Implemented |
| REQ-WIN-007 | Switching tabs, showing and hiding panes, and opening PRs never crashes the app or stalls its layout. | UN-9 | RC-09 | UI:tab-and-pane-stress; V-2026-11-03/V6, V7 (16 tab switches with comments toggled). | Implemented |

## Overview tab (OVR)

| ID | Requirement | Need | Control | Verified by | Status |
| --- | --- | --- | --- | --- | --- |
| REQ-OVR-001 | The Overview shows the PR's title, description, comments and reviews as GitHub renders them, with mergeability, review status by reviewer, checks sorted by urgency, and labels. | UN-2 | RC-02 | T:PullRequestOverviewTests.decodesMetadata, .checksMappedAndSortedByUrgency, .timelineSkipsPendingAndBodylessCommentReviews, .reviewerStatusKeepsLatestVerdict | Implemented |
| REQ-OVR-002 | Rendered PR content runs no JavaScript of its own. A clicked link, including one marked `target="_blank"`, opens in the default browser. | UN-8 | RC-16 | I: `HTMLView` sets `allowsContentJavaScript = false`, and its `WKUIDelegate` sends new-window links to the browser. **Gap:** UI:link-opens-browser. | Implemented |
| REQ-OVR-003 | Relative times ("5 minutes ago") are updated every minute. Anything older than 30 days shows its date. | UN-2 | RC-17 | **Gap:** no test. | Implemented |
| REQ-OVR-004 | The user can post a comment to the conversation, and quote any comment into the draft. | UN-4 | — | T:PullRequestOverviewTests.quotingMarkdown; UI:post-comment. **Gap:** quoting in the UI. | Implemented |

## Diff and Files tab (DIF)

| ID | Requirement | Need | Control | Verified by | Status |
| --- | --- | --- | --- | --- | --- |
| REQ-DIF-001 | The diff is parsed exactly as GitHub's unified diff gives it: both sides' line numbers, several files and hunks, added, deleted, renamed and binary files, the "No newline" marker, and git-quoted or non-ASCII paths. | UN-3 | RC-01 | T:DiffParserTests (all 7); L:LiveGitHubTests.loadsRealPullRequest | Implemented |
| REQ-DIF-002 | Show Full File fills in the lines between and around the hunks from the file at the PR's head commit, numbering both sides. If the contents don't match the diff, Maser shows an error instead of a merged file. | UN-3 | RC-03 | T:FullFileTests (6 offline); L:LiveFullFileTests.expandsRealFile | Implemented |
| REQ-DIF-003 | Lines added by Show Full File are for reading only. Commenting on one explains that GitHub takes comments only on lines in the diff, and posts nothing. | UN-3, UN-4 | RC-05 | T:FullFileTests.fillsGapsAroundHunks (no comment side on added lines). **Gap:** UI:comment-on-expanded-line. | Implemented |
| REQ-DIF-004 | The file tree lists directories first, collapses single-child directory chains, shows each file's status and comment count, and is as wide as its widest row, from 160 to 360 pt. | UN-3 | — | T:FileTreeTests (all 3); T:PullRequestOverviewTests.filePathsInDisplayOrder. **Gap:** the width (visual). | Implemented |
| REQ-DIF-005 | Holding `j`/`k` moves the cursor at the key-repeat rate without jitter. The diff scrolls only when the cursor would leave the view. | UN-10 | — | U: the user, PR #13 (V-2026-11-03/V2). **Gap:** UI:held-cursor. | Implemented |
| REQ-DIF-006 | Switching between hunks and the full file, refreshing, and returning to a PR keep the cursor on the same line, or the nearest one if that line is gone. | UN-5 | — | T:FullFileTests.matchesLinesAcrossViews. **Gap:** UI:cursor-survives-refresh. | Implemented |
| REQ-DIF-007 | Show Full File doesn't fetch files over 4 MB, and says why. | UN-10 | — | L:LiveFullFileTests.expandsRealFile (limit). | Implemented |
| REQ-DIF-008 | Review threads on the selected file, including outdated ones and pending drafts, are listed in the comments pane in line order with outdated threads last, and marked at their lines in the diff. Selecting a thread scrolls the diff to its line. | UN-2, UN-4 | — | T:ReviewThreadTests.decodesThreads; L:LiveGitHubTests.loadsRealPullRequest (every current thread maps to a line). **Gap:** UI:thread-markers. | Implemented |

## Commenting and reviewing (CMT)

| ID | Requirement | Need | Control | Verified by | Status |
| --- | --- | --- | --- | --- | --- |
| REQ-CMT-001 | The user can comment on the cursor line, or on a `V` range within one hunk, on the old or new side. The comment joins the user's pending review, which only they can see until they submit. | UN-4 | RC-20 | T:CommentTargetTests.commentableLines, .singleLine, .rangeAcrossSides, .rangeIsClippedToTheCursorsHunk; T:ReviewThreadTests.decodesReviewContext; L:LiveReviewWriteTests.pendingReviewRoundTrip | Implemented |
| REQ-CMT-002 | The user can reply to a thread. A reply joins the pending review if there is one; otherwise it's posted at once, as GitHub does. | UN-4 | — | L:LiveReviewWriteTests.pendingReviewRoundTrip (partly). **Gap:** a reply without a pending review. | Implemented |
| REQ-CMT-003 | Finish Review submits the pending review with an optional summary and a verdict: Comment, Approve or Request changes. The verdict starts at Comment every time. Submit is disabled when GitHub would reject the review for lacking a summary. | UN-4 | RC-07 | **Gap:** UI:finish-review-defaults (the logic is in the app target, so it has no unit test). | Implemented |
| REQ-CMT-004 | Discarding a pending review asks for confirmation, naming how many draft comments will be deleted. | UN-9 | RC-08 | I: `FinishReviewView` confirmation dialog. **Gap:** UI:discard-confirms. | Implemented |
| REQ-CMT-005 | A comment GitHub doesn't create is shown as an error, never as posted. This includes the null thread GitHub returns for a line outside the diff. | UN-4, UN-8 | RC-05 | L:LiveReviewWriteTests.pendingReviewRoundTrip (README line 40 throws `rejected`) | Implemented |
| REQ-CMT-006 | The user can delete their own draft comments. | UN-4 | — | L:LiveReviewWriteTests.pendingReviewRoundTrip | Implemented |
| REQ-CMT-007 | Line comments and reviews are posted only for the head commit of the diff the user saw. The diff and that commit are loaded together, and a load during a push is retried. A review is pinned to the commit (`commitOID`). Just before a new line comment or a submit, Maser checks the PR's head; if it has moved, nothing is posted, the text is kept, and Maser says to refresh. A line comment placed on an older diff must be placed again after the refresh. | UN-3, UN-8 | RC-04 | T:CommitPinningTests, L:LiveReviewWriteTests.reviewIsPinnedToCommitSeen, UI:head-moved-blocks-posting | Implemented |
| REQ-CMT-008 | Unsent text, meaning the conversation comment, line comment or reply drafts, and the review summary, survives a crash or quit and is restored when the PR is opened again. | UN-9 | RC-10 | Planned: T for the store, UI:draft-survives-relaunch. | **Proposed** (#19) |
| REQ-CMT-009 | Every place that posts, including the comment boxes and Finish Review, names the GitHub account it will post as, and Finish Review names the PR. | UN-8 | RC-12 | Planned: UI:finish-review-names-pr-and-account. | **Proposed** (#20) |

## Keyboard (KEY)

| ID | Requirement | Need | Control | Verified by | Status |
| --- | --- | --- | --- | --- | --- |
| REQ-KEY-001 | Every user action is a command with a menu shortcut, vim-style keys, or both. No default key sequence is hidden by a shorter one. | UN-5 | — | T:KeymapTests.defaultsMatchSequences, .defaultScrollBindings | Implemented |
| REQ-KEY-002 | Vim-style keys pause while the user types in a text field or editor. Esc leaves a multi-line editor, and cancels a half-typed sequence. | UN-5 | RC-06 | UI:typing-pauses-keys. | Implemented |
| REQ-KEY-003 | While the queue has the keys, keys it doesn't use go on to the open review. `/` focuses the filter only while the queue has the keys; ⌘F works from anywhere. | UN-5 | RC-06 | UI:key-routing; V-2026-11-03/V10. **Gap:** ⌘F from the review. | Implemented |
| REQ-KEY-004 | A comment box opened by a key (`c`, `R`) keeps keyboard focus until the user leaves it. | UN-5 | — | UI:comment-box-keeps-focus; V-2026-11-03/V8. **Gap:** `R` (reply). | Implemented |
| REQ-KEY-005 | Help → Keyboard Shortcuts (`?`) lists the bindings currently in effect, including the user's changes. | UN-5, UN-6 | — | **Gap:** UI:shortcuts-window. | Implemented |

## Configuration (CFG)

| ID | Requirement | Need | Control | Verified by | Status |
| --- | --- | --- | --- | --- | --- |
| REQ-CFG-001 | Maser reads `$XDG_CONFIG_HOME/maser/config.toml` (default `~/.config/maser/config.toml`; symlinks allowed). Changes apply when the file is saved, without a restart. | UN-6 | — | **Gap:** UI:config-reload. | Implemented |
| REQ-CFG-002 | Each bad entry in the config is reported in a banner in every window and skipped, and the rest still applies. A file that doesn't parse keeps the previous config in effect. | UN-6 | RC-18 | T:KeymapTests.reportsProblemsButKeepsTheRest, .invalidOnlyValueKeepsDefaults, .invalidTOMLThrows, .reportsShadowedSequences; T:SettingsTests.reportsProblems, .wrongTypeThrows, .readsQueue | Implemented |
| REQ-CFG-003 | ⌘, opens the config, creating a commented template on first use. The template lists every command and setting, and loads as the defaults. | UN-6 | — | T:KeymapTests.templateParsesAsDefaults; T:SettingsTests.templateHasSettings | Implemented |
| REQ-CFG-004 | A key binding set in the config replaces that command's defaults, and takes its keys away from any other command. `"none"` removes a binding. | UN-6 | — | T:KeymapTests.emptyConfigIsDefaults, .overridesAndUnbinds, .userBindingStealsKeysFromDefaults; T:KeyBindingParserTests (all 6) | Implemented |
| REQ-CFG-005 | Settings: `[diff] view` (hunks or full), `[github] gh`, `[queue] sections` and `[queue] searches`. | UN-6, UN-7 | — | T:SettingsTests.readsSettings, .readsQueue, .emptyConfigIsDefaults | Implemented |

## Platform and packaging (PLT)

| ID | Requirement | Need | Control | Verified by | Status |
| --- | --- | --- | --- | --- | --- |
| REQ-PLT-001 | Maser runs on macOS 26 and later, and builds with Swift 6.2 and the Xcode command-line tools. | UN-7 | — | I: `Package.swift` (`.macOS(.v26)`, tools 6.2); built and tested with those minimums on the home Mac. **Gap:** never run on macOS 26 or built with Swift 6.2. | Implemented |
| REQ-PLT-002 | `scripts/bundle` builds `Maser.app`, signed ad hoc, with no developer account. Built on the Mac that runs it, the app isn't quarantined. | UN-7 | — | I: `codesign --verify --strict` in the script. **Gap:** never built on the work Mac. | Implemented |
| REQ-PLT-003 | The first window appears within 0.5 s of launch, and the app comes to the front on launch and on a Dock click. | UN-10 | — | Measured about 170 ms (PR #11 session). **Gap:** coming to the front, which needs an unlocked screen; no repeatable test. | Implemented |
