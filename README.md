# maser

A native macOS app for reviewing GitHub pull requests.

Maser talks to GitHub through the [`gh` CLI](https://cli.github.com), so it uses whatever account `gh` is logged in to and never stores credentials itself.

## Requirements

- macOS 27, Xcode 27 (Swift 6.4)
- `gh`, logged in (`gh auth login`)

## Running

```sh
swift run Maser                                   # review queue
swift run Maser https://github.com/owner/repo/pull/123   # open a PR directly
```

The queue lists open PRs requesting your review; double-click one (or ⌘O to paste any PR URL) to open a review window. Each window has tabs:

- **Overview** — title, description, comments and reviews (rendered by GitHub), plus mergeability, review status, CI checks and labels.
- **Files** — changed files, diff, and inline review comments. Selecting a comment thread scrolls the diff to its line.

## Keyboard

Every action is a menu command; shortcuts are defined in one place (`Sources/Maser/Keymap.swift`).

| Action | Shortcut |
| --- | --- |
| Open pull request | ⌘O |
| Refresh | ⌘R |
| Open on GitHub | ⇧⌘O |
| Overview / Files tab | ⌘1 / ⌘2 |
| Show/hide comments | ⌥⌘0 |
| Next / previous file | ⌥⌘↓ / ⌥⌘↑ |
| Next / previous comment thread | ⌃⌘↓ / ⌃⌘↑ |

## Tests

```sh
swift test
MASER_LIVE_TESTS=1 swift test   # also hits GitHub via gh
```
