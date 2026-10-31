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

Every action is a command you can trigger two ways:

- **Menu shortcuts** (always available), e.g. ⌘1 / ⌘2 for the Overview / Files tabs.
- **Vim-style keys**, active whenever you're not typing in a text field.

| Action | Menu | Vim-style |
| --- | --- | --- |
| Open pull request | ⌘O | |
| Refresh | ⌘R | `r` |
| Open on GitHub | ⇧⌘O | `o` |
| Overview / Files tab | ⌘1 / ⌘2 | `g o` / `g f` |
| Show/hide comments | ⌥⌘0 | `i` |
| Next / previous file | ⌥⌘↓ / ⌥⌘↑ | `j` / `k` |
| Next / previous comment thread | ⌃⌘↓ / ⌃⌘↑ | `n` / `N` |
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
```

Keys are characters (`j`, `J` for shift+j, `?`), named keys (`up`, `down`, `left`, `right`, `enter`, `tab`, `space`, `esc`, `backspace`, `delete`, `pageup`, `pagedown`, `home`, `end`), optionally with `ctrl+`, `opt+`, `shift+`, `cmd+` (menu shortcuts only). Binding keys to a command takes them away from whatever had them by default. Esc cancels a half-typed sequence.

To debug bindings: `/usr/bin/log stream --predicate 'subsystem == "dev.maser"' --level debug`.

## Tests

```sh
swift test
MASER_LIVE_TESTS=1 swift test   # also hits GitHub via gh
```
