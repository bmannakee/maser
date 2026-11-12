# User needs

What the user needs from Maser, in their terms. Requirements trace back to these, and validation shows they're met.
Draft 1, 2026-11-03.

| ID | Need | Why |
| --- | --- | --- |
| UN-1 | I can see the pull requests that need my attention as soon as I open the app: ones where my review is requested, ones I wrote, and ones I'm involved in. | Without them the app opens on nothing; finding PRs in a browser is what Maser replaces. |
| UN-2 | I can read a PR's description, conversation, reviews, checks, labels and merge status, as GitHub shows them. | A review decision needs the whole context, not only the code. |
| UN-3 | I can read exactly what a PR changes, either as hunks or as the whole file with the changes in place, and trust that it matches GitHub. | Approving code I didn't actually see, or saw wrongly, defeats the review. |
| UN-4 | I can comment on a line or a range, reply to threads, and submit a review as Comment, Approve or Request changes. My line comments stay private until I submit. | This is the core of reviewing. |
| UN-5 | I can do all of it from the keyboard with vim-style keys. Keys always act where I expect, with no surprises. | That's how I work fastest. A key acting on the wrong PR or pane is worse than no key. |
| UN-6 | I can configure keys and behavior in a plain-text file in my dotfiles, and mistakes in it are reported, not silently applied. | I keep my setup in dotfiles across machines. |
| UN-7 | I can use Maser on a Mac my organization manages: macOS 26, no admin rights, no unsigned apps, and the `gh` already installed. | Much code review happens on managed machines, where the reviewer can't install or change much. |
| UN-8 | Maser never exposes my GitHub credentials, and acts only as me, only on the PR and line I intend. | Actions under my name are visible to my colleagues, and may be part of a regulated record. |
| UN-9 | I don't lose review work I've written, whether to a crash, a quit or a slip of the keyboard. | Rewriting a careful review is costly, and it gets skipped. |
| UN-10 | Maser is quick: it opens fast, moves between PRs instantly, and scrolls smoothly. | Slowness pushes me back to the browser. |

## Planned needs

These needs come from features that aren't built yet. Requirements are drafted against them with the status `Planned`,
and the needs are validated once those are built. Added 2026-11-12 (#32).

| ID | Need | Why | Status |
| --- | --- | --- | --- |
| UN-11 | I can talk to an agent about the PR I'm reviewing, and it can read the code around the change, not only the diff, from the repository the PR comes from. | Understanding a change often means reading code it doesn't touch: callers, state, configuration. Asking is faster than hunting, especially in code I didn't write. | Built (the conversation, #32); not yet validated |
| UN-12 | I can see the change drawn: the parts of the repository the PR touches as a diagram, such as a state machine, call graph or data flow, with what the PR changes marked. I can ask for new kinds of diagram as I think of them. | Some changes only make sense as a structure: a state machine's transitions, the direction of a dependency. A picture shows what a diff hides. | Built (the canvas, #32); not yet validated |
| UN-13 | The agent can add line comments to my pending review, and I can always tell its comments from mine before I submit. | Turning a finding into a well-placed comment is tedious, but everything I submit goes out under my name. | Built (#32); not yet validated |
| UN-14 | Code reaches the agent only for the organizations and hosts I've allowed. The agent can't change my working copy, run code, or act anywhere except my pending review. | The code I review may be confidential to its owner, the review record may be regulated, and a PR can be written to attack its reviewer. | Built (#32); not yet validated |
