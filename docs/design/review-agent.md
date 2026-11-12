# Review agent and canvas: design

Planned feature, #32. Draft 1, 2026-11-12. This document is a design input. The needs are UN-11 to UN-14, the
requirements are the AGT and CNV areas in [requirements.md](requirements.md), and the hazards are HAZ-18 to HAZ-25 in
the [risk file](risk-management.md). Nothing here is built yet.

## What it is

A pane beside the review where the user talks to an agent about the open PR. The agent:

- reads the PR's context (description, diff, threads) and the repository at the PR's head commit;
- answers questions about the change;
- draws diagrams on a canvas, such as the state machine a PR changes, with the changed parts marked and each element
  linked to its source lines;
- adds line comments to the user's pending review, badged as the agent's.

The agent's output helps the user read the change. It doesn't replace reading it: the diff stays what's reviewed, and
nothing the agent does changes review state.

## Decisions

Made with the user on 2026-11-12, in the review of #33.

| Decision | Choice | Why | Rejected |
| --- | --- | --- | --- |
| How the agent runs | The user's own `claude` CLI, run headless, as Maser runs `gh` | Maser never handles an Anthropic credential (as RC-11 does for GitHub). The user's login, model and org policy apply. Claude Code supplies the agent loop and file tools. Nothing new to sign or ship except a small helper. | A bundled Agent SDK helper: it needs a Node or Python runtime, signed, on managed Macs. Calling the API from Swift: Maser would store a key and rebuild the loop and tools. |
| Code owners' approval | Off until `[agent] allow` names the PR's owner or host | Whether code may go to the model provider is its owner's decision, which Maser can't know. A default of off makes allowing it a deliberate step by the user, who is responsible for having that approval (HAZ-21). | On everywhere; home only. |
| What the agent may write | Line comments in the pending review, private until submit | Useful, and the user still submits. The comments carry the user's name, so they're badged in Maser and Finish Review asks before submitting unread ones (HAZ-19). | Suggestions the user must accept one by one (safer, slower). Posting directly (puts unread text in a shared record). |
| Repository access | A read-only checkout of the head commit, owned by Maser | The agent sees what the PR contains, and can't touch the user's clone (HAZ-22). | Running builds and tests: a PR's code would run on the user's Mac (HAZ-23). |
| Attribution | Each agent comment says, in its posted text, that an agent drafted it, naming the model | The comment carries the user's name, and colleagues should know what they're reading (HAZ-19). | No attribution; a setting with a default. |
| Where it lives | A third tab, Agent, beside Overview and Files | The canvas needs room, and the Files tab already has three columns. | A side pane on both tabs. |
| Model and effort | `[agent] model` and `[agent] effort`, which the Agent tab can change for one PR | The right model and effort are likely to differ by PR. | Always `claude`'s own settings. |
| Conversation storage | `claude`'s own session store, under the user's home folder | Acceptable for this iteration; revisit systematically if Maser gains other users. | Maser asking `claude` not to persist, keeping its own transcript. |

## Architecture

```
┌───────────────────────── Maser.app ──────────────────────────┐
│ ReviewModel ── AgentSession (one per PR) ── Canvas (WKWebView)│
│                    │  ▲ stream-json             ▲ diagrams    │
│                    ▼  │                         │             │
│              claude --print ...           AgentToolServer     │
│                    │                     (Unix socket, token) │
│                    │ spawns (stdio MCP)        ▲              │
│                    └──────► maser-agent-tools ─┘              │
└───────────────────────────────────────────────────────────────┘
  claude's file tools read only: ~/Library/Application Support/<bundle>/Checkouts/<host>/<owner>/<repo>@<commit>
```

- **`AgentSession`** (app, `@MainActor @Observable`), one per PR. It owns the conversation and keeps one `claude`
  process per conversation, sending user messages as stream-json and reading events back: text, tool calls, results
  and cost. It resumes a conversation after a relaunch with `--resume <session-id>`.
- **The command line** is built in MaserCore (`AgentCommandLine`), so it can be unit tested:
  `--print --input-format stream-json --output-format stream-json --verbose`, `--tools Read,Grep,Glob`,
  `--strict-mcp-config --mcp-config <maser's only>`, `--setting-sources user` (never `project` or `local`, which would
  load the PR's `.claude/` settings and hooks), `--permission-mode` set so nothing outside the tool list can be
  approved, `--model`, `--effort`, `--max-budget-usd`, `--append-system-prompt` with Maser's instructions, and the checkout as the working
  directory. These options exist in `claude` 2.1.322. What each actually does is checked in the spike.
- **`maser-agent-tools`** is a small executable in the app bundle. `claude` starts it as a stdio MCP server, and it
  forwards each call to the running Maser over a Unix socket. The socket lives in a per-session folder that only the
  user can read, and each call carries a per-session token. Maser listens on no network port.
- **The whole PR, not one commit.** "The head commit" names the PR's state: the checkout is the repository at the
  head, and the diff is the whole PR from the merge base, every commit in it, as the Files tab shows it.
- **Maser's tools** (the only ones besides file reading):
  - `pr_context`: the description, the diff, the list of commits with their messages, and the threads, from what Maser
    already loaded.
  - `add_review_comment`: path, line or range, side, body. It runs the user's own posting path: `ReviewModel`'s head
    and account checks, and the comment target rules. Maser appends the attribution line; the agent can't leave it out.
  - `show_diagram`: format (`mermaid` or `dot`), source, title, and per-element citations and change marks.
- **The checkout** (`AgentCheckout`, MaserCore). Maser keeps a bare clone per repository in Application Support. It
  borrows objects from the user's local clone, opened read-only through git's alternates, and otherwise fetches with
  `gh repo clone`. It checks out the head commit as a detached worktree and makes its files read-only. Where a local
  clone lives comes from `[agent] repositories` (folders to search), matched by remote URL.
- **The canvas** is a `WKWebView` with JavaScript on but only for the bundled renderers: [Pele](https://github.com/obsidianmd/pele)
  (MIT, from Obsidian) for Mermaid, and Viz.js for DOT. Pele suits untrusted source: it ignores `click` callbacks,
  escapes label text rather than rendering HTML, can turn links and images off (`links: false`, `images: false`),
  and rejects oversized source and output. Its layout differs from Mermaid's own, which doesn't matter here.
  Its `render()` returns SVG text, so if it runs in JavaScriptCore without a page, the canvas could show the SVG with
  no script at all. A content
  security policy allows no network and no inline or remote script, and pages navigate nowhere. Diagram source goes in
  as data and is checked first: no HTML labels, no `click` callbacks, no links. Each rendered element reports its ID,
  so Maser can draw citation and change-mark flags over it and open its lines when it's chosen.

## The grounding check (RC-29)

The agent states facts the user may not verify, so whatever can be checked mechanically is:

1. **Citations.** Each element may cite `path:start-end`. Maser checks that the path exists in the checkout at the
   commit and that the lines are in range. A citation that doesn't resolve is flagged on the element.
2. **Change marks.** An element marked `added`, `removed` or `changed` must cite lines the diff touches. An element
   citing touched lines must be marked. Either mismatch is flagged.
3. **Unsourced diagrams.** A diagram with no citations is labeled as such.

This can't show that a diagram is complete, for example that no state was left out. That's why HAZ-18 stays Medium,
and why the evaluation below measures it.

## Verification plan

| Level | What |
| --- | --- |
| Unit | Command line (`AgentCommandLine`), stream-json decoding, checkout git commands in a temporary repository, `[agent]` settings and allow matching, diagram source checking, citation and change-mark checks against parsed diffs. |
| UI scenarios | A `fake-claude`, like `fake-gh`, that replays recorded stream-json sessions and drives tool calls into Maser: agent-conversation, agent-off-until-allowed, agent-follows-head, agent-comments-marked, canvas-shows-diagram, canvas-rejects-script, canvas-follows-citation, agent-keys. |
| Live | Opt-in (`MASER_LIVE_AGENT_TESTS=1`, costs money): a real `claude` in a checkout with a planted `.claude/settings.json` hook and a planted MCP server, neither of which may run; a comment added to bmannakee/maser#1 and removed. |
| Evaluation | The agent's accuracy, as evidence for HAZ-18's probability: a set of PRs on this repository with known answers (a state machine changed in a known way, a seeded injection in the description). Each run is scored on missed and invented elements, wrong change marks, and whether an injection changed the answer. |
| Usability | HRUS-9 to HRUS-12 with the user, on a release build. |

## Increments

Each one is a PR that updates these documents, as usual.

1. **Spike** (a verification record, no product code). Run `claude` headless with the planned command line. Record the
   stream-json event shapes. Confirm that a planted project hook and MCP server don't run, and that the stdio-to-socket
   helper works. Record the `claude` version tested, as the minimum. Render sample state machines with Pele: check that
   its SVG gives each element an ID from the diagram source (needed to flag citations), and whether `render()` works
   in JavaScriptCore without a page.
2. **Conversation:** the pane, the checkout, the allow list, read tools, `pr_context`, commit pinning, the spending cap,
   and showing every action (REQ-AGT-001 to 006, 009 to 011).
3. **Canvas:** the renderers, checking, citations and change marks (REQ-CNV-001 to 006).
4. **Comments:** `add_review_comment`, badges, and the Finish Review question (REQ-AGT-007, 008).
5. **Evaluation:** the accuracy set, run before the agent is relied on to review regulated software.

## Open questions

1. **More diagram kinds.** Mermaid and DOT cover state machines, flows, sequences and class diagrams. Data plots or
   custom layouts would need Vega-Lite or similar, with the same checking. Leave it until a need appears.
