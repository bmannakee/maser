# Verification record: a diff GitHub won't serve, 2026-11-25

What was checked on reading a PR's diff from the user's clone when GitHub refuses it (REQ-DIF-012, HAZ-30, RC-39, #74).

- **Software:** branch `large-pr-diff`, from main at `1114342`.
- **Environment:** a Mac with macOS 27.0.1 and Xcode 27.1; git `/usr/bin/git`. Not macOS 26.
- **How:** `scripts/check` (unit tests in throwaway git repositories, and with a stand-in `gh`), then `scripts/check-ui`.
- **Performed by:** Claude Code (agent), at the user's request.

## Summary

| # | Check | Result | Led to |
| --- | --- | --- | --- |
| V1 | A 25,000-line PR in a throwaway origin and clone | `AgentCheckout.diff` returned the diff, `DiffParser` read it as one added file of 25,000 lines, and the clone's files were unchanged afterward. | REQ-DIF-012 |
| V2 | A local ref that disagrees with the commits given | The diff followed the commits it was given; the clone's own `main` held a different edit and did not show. | REQ-DIF-012 |
| V3 | The user's git settings | With `diff.noprefix`, `diff.mnemonicPrefix` and `color.ui = always` set globally the text still had `a/` and `b/` prefixes and no color. Taking the prefix flags out of the command made the test fail, so it does check them. | REQ-DIF-012 |
| V4 | `diffAtHead` with a stand-in `gh` that refuses diffs | With a clone it asked for the base and head GitHub reported and loaded the files; with no clone it threw the message naming the repository and `repositories`; a failing clone gave a message saying so; a diff GitHub served never called the clone. | REQ-DIF-012 |
| V5 | The UI | `large-pr-needs-clone` passed, and all 29 scenarios passed. | REQ-DIF-012 |

## Not checked

- **A real refused diff.** No PR over 20,000 lines on real GitHub or GitHub Enterprise was loaded. The stand-in's refusal
  text is the one in #74, from compbio-pipeline#2978. The first real check is that PR, on the work Mac.
- **A real fetch of a PR head from GitHub** into the cache for a large repository, and how long it takes. The unit tests
  fetch from a local origin.
- **The base moving while the clone's diff loads.** The code reads the base again afterward and retries if it changed;
  no test moves it.
- **Posting a comment from a clone-computed diff.** #74 reports it verified for a diff made the same way by another tool
  on compbio-pipeline#2978; maser's own path wasn't posted from.
- **macOS 26**, and mouse or visual layout of the message.

## Details

### V1: a 25,000-line PR

`LocalDiffTests.diffsALargePull`: the origin gets a branch with a 25,000-line `Big.txt` on top of the main commit and
`refs/pull/8/head` pointing at it. The head isn't in the clone, so it is fetched from the origin into maser's cache.
`DiffParser.parse` gave one file, `Big.txt`, status added, 25,000 additions. The snapshot of every file in the clone,
with size and modification time, was the same before and after (RC-23).

### V2: stale refs

`LocalDiffTests.ignoresStaleRefs`: the clone's `main` was given a commit that changes `Door.swift` differently. The diff
of the main commit against the PR's head still showed only the PR's change, `struct Door {}` to
`struct Door { var open = false }`.

### V3: git settings

`LocalDiffTests.independentOfGitConfig` points `GIT_CONFIG_GLOBAL` at a file with settings that change a diff's form.
The text still began `diff --git a/Door.swift b/Door.swift` and held no escape characters. With the two prefix flags
removed from the command the first expectation failed, then they were restored.

### V4: `diffAtHead`

`LargeDiffTests` runs `GitHubCLI` against a shell script standing in for `gh`: it answers GraphQL, prints `baseRefOid`
for the base query, and answers `pr diff` with GitHub's refusal text (or a small diff). The cases are in the Summary.

### V5: the UI

`large-pr-needs-clone` overrides `pr diff` with the refusal and the base query with a commit, opens a PR, and waits for
the Files tab's shown text: it contains "20,000 lines", "`repositories` under `[agent]`" and the repository, and not
gh's raw error. After the override is removed, refreshing loads the diff. The full `scripts/check-ui` run: 29 passed.
