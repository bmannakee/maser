# UI scenarios

Scripted runs through Maser's UI that check what unit tests can't reach: keys, focus, panes and layout. Each scenario
runs in a fresh launch of a debug build, against a fake `gh` that replays recorded GitHub responses.

```sh
scripts/check-ui                      # every scenario
scripts/check-ui key-routing          # some of them, by name
scripts/check-ui --record post-comment   # record what's missing, from the real gh (read-only)
```

Run it before merging a PR that changes the app. It needs an unlocked screen, and each scenario takes over the keyboard
and brings a window to the front for a few seconds, so leave the Mac alone while it runs. The script holds the display awake with `caffeinate` for the run, so the screen can't lock partway through, but it can't unlock one that is already locked. The test app is a separate
bundle (`dev.maser.Maser.uitests`) with its own settings, so a Maser you're using isn't touched.

## How it works

| Piece | Where | What it does |
| --- | --- | --- |
| Scenarios | `Sources/Maser/UIScenarios.swift` | The steps and checks, one `UIScenario` each. Debug builds only. |
| Runner | `Sources/Maser/UIScenarioRunner.swift` | Starts the scenario named by `MASER_UI_SCENARIO` in the first main window. It presses keys by posting real key events, waits for and checks the window's state, writes `PASS` or `FAIL: …` to `MASER_UI_RESULT`, and exits. |
| Fake `gh` | `Sources/fake-gh` | Answers each `gh` command from `recordings/`, or from overrides a scenario writes. It logs every command, so a scenario can check what Maser sent. |
| Fake `claude` | `Sources/fake-claude` | Answers the review agent's messages in `claude`'s stream-json shapes, without a model. It starts Maser's real `maser-agent-tools` helper from the MCP config Maser gives it, so tool calls go through the real bridge. It logs its arguments and messages to `claude.jsonl`, which scenarios read as `app.claudeLog`. |
| Config | `config.toml` here | Points `[github] gh` and `[agent] claude` at the fakes, allows the agent for bmannakee, and sets the queue's searches to the recorded ones. |
| Launcher | `scripts/check-ui` | Builds, wraps the debug binary in `.build/MaserUITests.app`, and launches it once per scenario with its own config, `gh` state and log. Before each scenario it clears what the test app saved: settings, window state, and unsent text. |

The runner refuses to start unless `[github] gh` and `[agent] claude` are the fakes, so a scenario can never post to real
GitHub or spend money on a model. The agent reads a fixed folder (`MASER_AGENT_CHECKOUT`, debug builds only) instead of
a checkout, since the recorded PRs' commits can't be fetched without GitHub; the checkout itself is unit tested.

Posted key events go through the same path as typing: `KeyRouter`, the menus, and the focused view. Mouse clicks aren't
simulated, and neither is anything outside the app, such as a link opening the browser.

Menu items that depend on the focused window (Refresh and Filter Pull Requests were checked) stay disabled in the test
app, even with its window key, so scenarios use the vim-style keys for those commands (`r`, not ⌘R). Menu items that are
always enabled, such as ⌘0, work. In normal use these items work (checked by hand on 2026-11-10), so this is a limit of the
test app, not an app bug.

## Writing a scenario

1. Add a `static let` to `UIScenarios` and list it in `all`. Name it in kebab case, and start its title with the
   requirements it verifies: `UIScenario("queue-keys", "REQ-QUE-007: …") { app in … }`.
2. Drive it with `app.press("g f")` (keys written as in `config.toml`), `app.type("text")`, and
   `app.openFromQueue(number)`. Check with `app.expect(condition, "what it means", app.summary)`, or
   `app.waitUntil("what it means") { condition }` for anything asynchronous.
3. Make GitHub fail or answer a mutation with `app.overrideGH([...])`, and read what was sent from `app.ghCalls`.
   For layout, diff rows record where they and their text were drawn in `LayoutProbe` (only during a scenario), and
   `app.snapshot("name")` saves a PNG of the window beside the scenario's log, for looking at by eye.
   To check wording, a view records the text it shows with `.shownText("name", text)` (only during a scenario), and the
   scenario reads `ShownText.values["name"]`. SwiftUI doesn't put most of the review's views in the accessibility tree,
   so reading the screen that way doesn't work.
   To check what survives a crash, call `app.crash()`: it kills the app without warning, and `scripts/check-ui` launches
   the scenario again, keeping what was saved, with `app.relaunched` set. Branch on it, as
   `draft-survives-relaunch` does.
4. Cite it from each requirement as `UI:name`, before any `Gap`. `maser-trace` checks both directions.
5. Run it with `--record` once to record any GitHub data it needs, then without, and commit the new recordings.

## Recordings

Each file in `recordings/` is one `gh` command's exact arguments and its output, named by the command and a hash of the
arguments. They're real responses from bmannakee/maser, recorded with `--record`. Recording runs only read-only commands
through the real `gh`. The fake refuses to forward mutations, so those always need an override.

A command with no recording fails with "fake-gh: no recording for …", which shows in the scenario's log. Changing the
arguments Maser sends to `gh` (a new field in a query, say) changes the hash, so after such a change, delete the
recordings and record them all again with `scripts/check-ui --record`.

The scenarios use PRs #16 and #13 (merged) and #1 (the closed test PR), by number, from the queue searches in
`config.toml`.

## When a scenario fails

`scripts/check-ui` prints the scenario's steps up to the failure, with the window's state, and the directory with each
scenario's full log and `gh` call log (`gh/calls.jsonl`). A scenario with no result crashed or hung: look in
`~/Library/Logs/DiagnosticReports` for a `Maser-*.ips` report.
