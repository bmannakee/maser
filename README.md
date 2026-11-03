# maser

A native macOS app for reviewing GitHub pull requests.

Maser talks to GitHub through the [`gh` CLI](https://cli.github.com), so it uses whatever account `gh` is logged in to and never stores credentials itself.

## Requirements

- macOS 26 or later; Xcode 26 or its command-line tools (Swift 6.2 or later)
- `gh`, logged in (`gh auth login`)

## Running

```sh
swift run Maser                                   # review queue
swift run Maser https://github.com/owner/repo/pull/123   # open a PR directly
```

To use it as a regular app (Dock icon, Spotlight, Login Items), build `Maser.app`:

```sh
scripts/bundle                    # builds .build/Maser.app, signed for this Mac
cp -R .build/Maser.app /Applications/
```

The bundle is signed ad hoc, with no developer account. Built on the Mac that runs it, it isn't quarantined, so Gatekeeper doesn't ask about it. To run it on another Mac, build it there, or sign it with a Developer ID and notarize it.

The queue lists open PRs requesting your review; double-click one (or ⌘O to paste any PR URL) to open a review window. Each window has tabs:

- **Overview** — title, description, comments and reviews (rendered by GitHub), plus mergeability, review status, CI checks and labels.
  Write a comment in the box at the bottom (`c` to jump there, ⌘↩ to post, Esc to leave it); **Quote reply** on any comment quotes it into your draft.
- **Files** — changed files, diff, and inline review comments. Selecting a comment thread scrolls the diff to its line.
  Move the line cursor with `j`/`k` (or click the line numbers), select a range with `V` (or shift-click), and press `c` to comment;
  `R` replies to the selected thread. Line comments collect in a pending review, visible only to you, until you
  **Finish Review** (`S`, toolbar) as Comment, Approve or Request changes. Replies join the pending review if you have one;
  otherwise they post immediately (GitHub's rule).
  `z a` shows the whole file instead of just the changed hunks (`z R` for every file, `z M` to go back); hunk
  navigation still jumps between the changes. GitHub only takes comments on lines in the diff, so the extra lines are
  for reading.

## Keyboard

Every action is a command you can trigger two ways:

- **Menu shortcuts** (always available), e.g. ⌘1 / ⌘2 for the Overview / Files tabs.
- **Vim-style keys**, active whenever you're not typing in a text field.

| Action | Menu | Vim-style |
| --- | --- | --- |
| Open pull request | ⌘O | |
| Refresh | ⌘R | `r` |
| Open on GitHub | ⇧⌘O | `o` |
| Comment (Overview: on the PR; Files: on the cursor line or selection) | ⌥⌘C | `c` |
| Reply to the selected thread | | `R` |
| Finish review | ⌥⌘R | `S` |
| Overview / Files tab | ⌘1 / ⌘2 | `g o` / `g f` |
| Show/hide comments | ⌥⌘0 | `i` |
| Next / previous line (Files) | | `j` / `k` |
| Select lines / cancel selection | | `V` / `esc` |
| Next / previous hunk | | `}` / `{` |
| Show full file / only changes (this file) | ⌥⌘E | `z a` |
| Show all files in full / only changes | | `z R` / `z M` |
| Next / previous file | ⌥⌘↓ / ⌥⌘↑ | `]` / `[` |
| Next / previous comment thread | ⌃⌘↓ / ⌃⌘↑ | `n` / `N` |
| Scroll diff down / up a page | | `ctrl+f` or `space` / `ctrl+b` or `shift+space` |
| Scroll diff down / up half a page | | `ctrl+d` / `ctrl+u` |
| Scroll diff down / up a line | | `ctrl+e` / `ctrl+y` |
| Top / bottom of diff | | `g g` / `G` |
| Open config file | ⌘, | |
| Keyboard shortcuts | ⌘/ | `?` |

Help → Keyboard Shortcuts (or `?`) lists the bindings currently in effect.

## Configuration

Maser reads `~/.config/maser/config.toml` (or `$XDG_CONFIG_HOME/maser/config.toml`), so it can live in your dotfiles; symlinks are fine. ⌘, opens it, creating a fully commented template listing every command on first use. Changes apply as soon as you save; mistakes show up in a banner in each window, and a file that doesn't parse leaves the previous bindings in place.

```toml
[keys]                          # menu shortcuts: need cmd, ctrl or opt
next-file = "cmd+ctrl+j"
refresh = "none"                # remove a shortcut

[keys.normal]                   # vim-style keys
next-file = ["j", "down"]       # several bindings
show-overview = "g g"           # sequences: space-separated keystrokes
previous-thread = "ctrl+p"

[diff]
view = "full"                   # open files in full; the default is "hunks"

[github]
gh = "~/.local/bin/gh"          # only if Maser can't find gh
```

Maser looks for `gh` in Homebrew, MacPorts, Nix, `~/.local/bin` and mise or asdf shims, then asks your login shell. Set `[github] gh` if it's somewhere else.

Keys are characters (`j`, `J` for shift+j, `?`), named keys (`up`, `down`, `left`, `right`, `enter`, `tab`, `space`, `esc`, `backspace`, `delete`, `pageup`, `pagedown`, `home`, `end`), optionally with `ctrl+`, `opt+`, `shift+`, `cmd+` (menu shortcuts only). Binding keys to a command takes them away from whatever had them by default. Esc cancels a half-typed sequence.

To debug bindings: `/usr/bin/log stream --predicate 'subsystem == "dev.maser"' --level debug`.

## Tests

```sh
swift test
MASER_LIVE_TESTS=1 swift test   # also hits GitHub via gh
MASER_LIVE_WRITE_TESTS=1 swift test   # creates and deletes a pending review on bmannakee/maser#1
```
