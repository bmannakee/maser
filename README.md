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

The queue lists open PRs requesting your review; double-click one (or ⌘O to paste any PR URL) to open a review window: changed files on the left, diff in the middle, review comments on the right (⌥⌘0 toggles them). Clicking a comment thread scrolls the diff to its line.

## Tests

```sh
swift test
MASER_LIVE_TESTS=1 swift test   # also hits GitHub via gh
```
