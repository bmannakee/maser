# Verification record: Show Full File from the clone, 2026-11-25

What was checked on reading a file at the PR's head from the user's clone, before asking GitHub (REQ-DIF-013, #74).

- **Software:** branch `full-file-from-clone`, from main at `05e64d6`.
- **Environment:** a Mac with macOS 27.0.1 and Xcode 27.1; git `/usr/bin/git`. Not macOS 26.
- **How:** `scripts/check` (tests in throwaway git repositories), then `scripts/check-ui`.
- **Performed by:** Claude Code (agent), at the user's request.

## Summary

| # | Check | Result | Led to |
| --- | --- | --- | --- |
| V1 | A file at a commit the clone has | The text came back, and the clone's files were unchanged afterward. | REQ-DIF-013 |
| V2 | A commit the clone lacks | nil, and the clone was unchanged: nothing was fetched. | REQ-DIF-013 |
| V3 | Paths and commits that aren't a plain file at a full commit ID | nil for a symlink, `.`, an empty path, a missing file, `-p`, a path with `..`, an empty or non-hex commit, `--all` and `HEAD`. The first run of this test failed for `.` (a folder): the first version read the first line of `ls-tree`'s listing. It now requires exactly one entry for exactly the path asked, and the test passes. | REQ-DIF-013 |
| V4 | A file over the limit | nil, so GitHub's path reports it as too large as before. | REQ-DIF-013 |
| V5 | The UI | 29 scenarios passed on the second run. The first run failed `typing-pauses-keys`; run alone it passed, and passed again on the unchanged main. I take it to be the known sensitivity to the Mac being used, but I didn't find its cause. | REQ-DIF-013 |

## Not checked

- **Speed.** Nobody timed Show Full File with and without the clone. #74 asks to measure first, and this is not
  that measurement.
- **The clone path in the UI.** The UI scenarios configure no `repositories`, so they exercise only the GitHub path.
- **A real Enterprise repository**, a partial clone, and a clone using filters or attributes. A partial clone is
  protected by `GIT_NO_LAZY_FETCH=1`, which no test sets up.
- **macOS 26.**

## Details

### V1–V4

`CloneFileTests` runs `AgentCheckout.fileContents(inClone:commit:path:maxBytes:)` against the checkout tests' fixture. For
V2 a commit is made on the origin after the clone: a fresh local clone shares all of the origin's objects, so the
fixture's own PR commit is in it and can't stand for a commit the clone lacks.
