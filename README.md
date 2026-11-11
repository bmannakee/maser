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

The queue lists open PRs in sections: **Review requested**, **Yours** and **Involving you** (you commented, were
mentioned or are assigned), plus any searches you add to `config.toml`. A PR shows only in the first section that finds
it, and empty sections are hidden. Type `/` (or ⌘F) to filter by title, repository, author or `#number`; Esc clears the
filter. Move with `j`/`k` and jump between sections with `]`/`[`.

The queue sits in the main window's sidebar, with the selected PR's review beside it. Clicking a PR, or pressing Return
on it, shows it and moves the keys to the review. The queue takes the keys back only when you press ⌘0 (or `g p`),
which also brings the main window forward from anywhere, or `e`, which shows and hides it; Esc in the queue goes back to
the review. `/` filters the queue only while it has the keys; ⌘F works from anywhere. While the queue has the keys, the ones it doesn't use (`c`,
`g f`, `S`…) still reach the open review. Reviews you've opened stay loaded, so switching between PRs is
instant. ⌥Return, or Open in New Window in the context menu, opens a PR in a window of its own, to compare two side by
side. ⌘O opens any PR by URL. Each review has tabs:

- **Overview** — title, description, comments and reviews (rendered by GitHub), plus mergeability, review status, CI checks and labels.
  Write a comment in the box at the bottom (`c` to jump there, ⌘↩ to post, Esc to leave it); **Quote reply** on any comment quotes it into your draft.
- **Files** — changed files, diff, and inline review comments. Selecting a comment thread scrolls the diff to its line.
  Move the line cursor with `j`/`k` (or click the line numbers), select a range with `V` (or shift-click), and press `c` to comment;
  `R` replies to the selected thread. Line comments collect in a pending review, visible only to you, until you
  **Finish Review** (`S`, toolbar) as Comment, Approve or Request changes. Replies join the pending review if you have one;
  otherwise they post immediately (GitHub's rule). If someone pushes after the diff loaded, Maser won't post a line
  comment or submit the review until you refresh (`r`), so nothing lands on a line or commit you haven't seen. A line
  comment then needs `c` on its line again; the text is kept. Every post button names the account `gh` will post as
  ("Comment as @you"), and Finish Review names the PR too. If `gh` switches accounts while Maser is open, the next post
  is refused and the new account shown, so you never post as an account you weren't shown.
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
| Filter the queue | ⌘F | `/` |
| Show the queue and give it the keys (from anywhere) | ⌘0 | `g p` |
| Show/hide the queue | | `e` |
| Open the selected PR (queue) / in a new window | | `enter` / `opt+enter` |
| Open on GitHub | ⇧⌘O | `o` |
| Comment (Overview: on the PR; Files: on the cursor line or selection) | ⌥⌘C | `c` |
| Reply to the selected thread | | `R` |
| Finish review | ⌥⌘R | `S` |
| Overview / Files tab | ⌘1 / ⌘2 | `g o` / `g f` |
| Show/hide comments | ⌥⌘0 | `i` |
| Next / previous line (Files), or PR (queue) | | `j` / `k` |
| Select lines / cancel selection | | `V` / `esc` |
| Next / previous hunk | | `}` / `{` |
| Show full file / only changes (this file) | ⌥⌘E | `z a` |
| Show all files in full / only changes | | `z R` / `z M` |
| Next / previous file, or queue section | ⌥⌘↓ / ⌥⌘↑ | `]` / `[` |
| Next / previous comment thread | ⌃⌘↓ / ⌃⌘↑ | `n` / `N` |
| Scroll diff down / up a page | | `ctrl+f` or `space` / `ctrl+b` or `shift+space` |
| Scroll diff down / up half a page | | `ctrl+d` / `ctrl+u` |
| Scroll diff down / up a line | | `ctrl+e` / `ctrl+y` |
| Top / bottom of diff, or first / last PR (queue) | | `g g` / `G` |
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

[queue]
sections = ["review-requested", "yours"]   # built-in sections to show; default adds "involving"
searches = [                               # more sections, in GitHub's search syntax
  { name = "maser", query = "repo:bmannakee/maser" },
  { name = "Team", query = "org:my-org team-review-requested:my-org/backend" },
]
```

Queue searches show open PRs unless the query picks a state (`is:closed`, `is:merged`). Quote phrases as on GitHub,
with TOML escapes: `query = "label:\"needs review\""`. Hover a section's heading to see its query.

Maser looks for `gh` in Homebrew, MacPorts, Nix, `~/.local/bin` and mise or asdf shims, then asks your login shell. Set `[github] gh` if it's somewhere else.

Keys are characters (`j`, `J` for shift+j, `?`), named keys (`up`, `down`, `left`, `right`, `enter`, `tab`, `space`, `esc`, `backspace`, `delete`, `pageup`, `pagedown`, `home`, `end`), optionally with `ctrl+`, `opt+`, `shift+`, `cmd+` (menu shortcuts only). Binding keys to a command takes them away from whatever had them by default. Esc cancels a half-typed sequence.

To debug bindings: `/usr/bin/log stream --predicate 'subsystem == "dev.maser"' --level debug`.

## Tests

```sh
swift test
MASER_LIVE_TESTS=1 swift test   # also hits GitHub via gh
MASER_LIVE_WRITE_TESTS=1 swift test   # creates and deletes a pending review on bmannakee/maser#1
```
