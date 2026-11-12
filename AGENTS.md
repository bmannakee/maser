# Maser — guide for contributors and coding agents

Maser is a native macOS app for reviewing GitHub pull requests, built for engineers who prefer the keyboard
and vim-style keys. This file holds the project's conventions. Read it before changing code; when a convention changes,
update it here in the same PR.

## Build, run, check

```sh
swift build                        # debug build
swift run Maser [PR URL…]          # run; the first URL opens in the main window, the rest in their own
scripts/check                      # format lint + build + tests + traceability; run before every commit
scripts/check-ui                   # UI scenarios against a fake gh; before merging app changes (needs an unlocked Mac)
scripts/bundle                     # release build wrapped in .build/Maser.app, signed ad hoc
swift run maser-trace --write      # regenerate docs/design/traceability.md after editing docs/design/
swift format --in-place --recursive Sources Tests Package.swift   # apply formatting
```

- Requires macOS 26 and Swift 6.2 (Xcode 26 or its command-line tools); `swift-tools-version: 6.2` is the lowest that
  allows `.macOS(.v26)`. Keep both minimums there: managed Macs may stay on macOS 26. A newer API needs an
  `if #available` check with a macOS 26 fallback.
- `MASER_LIVE_TESTS=1 swift test` also runs read-only tests against real GitHub through `gh`.
- `MASER_LIVE_AGENT_TESTS=1 swift test` runs the review agent's live tests with your own `claude` (after `swift build`,
  for the helper). They spend a few cents of model use each.
- `MASER_LIVE_WRITE_TESTS=1 swift test` writes to GitHub. It only touches the closed test PR bmannakee/maser#1
  and cleans up after itself. Write tests must never target any other PR.
- Products land in `.build/out` (`.build/debug` is a symlink). For a truly clean build, `rm -rf .build`.
- Any Python tooling goes through `uv` (`uv run`, `uv run --no-project python -c …`), never bare `python` or `pip`.

## Architecture

| Target | What goes there | May import |
| --- | --- | --- |
| `MaserCore` (library) | Models, parsing, GitHub access, keymap and config logic. Anything that can be unit tested. | Foundation, TOMLDecoder |
| `Maser` (executable) | SwiftUI views, AppKit glue, window and menu wiring, `@Observable` view models. | MaserCore, SwiftUI, AppKit, WebKit |
| `MaserCoreTests` | Swift Testing tests for MaserCore. | MaserCore |
| `Traceability`, `maser-trace` | Development tool: checks the links in `docs/design/` (see its README). Not part of the app. | Foundation |
| `TraceabilityTests` | Tests for the traceability checker. | Traceability |
| `fake-gh` | Development tool: a stand-in for `gh` that replays `Tests/UIScenarios/recordings`, for the UI scenarios. | Foundation |
| `maser-agent-tools` | The review agent's MCP helper, which `claude` starts; it forwards tool calls to Maser's socket. Shipped in the app bundle. | MaserCore, Foundation |

Rules:

- **GitHub goes only through `gh`,** via `GitHubCLI` in MaserCore. The app never sees or stores a token.
  Use GraphQL (`GitHubCLI.graphQL`) when REST is missing data (REST omits pending review comments, for example).
- **Keep logic out of views.** If a view needs a computation, put it in MaserCore (testable) or in the view model.
- **One model per review.** `ReviewModel` (`@MainActor @Observable`) owns one PR's review state and actions.
  Views read it, and commands reach it through `perform(_:)`. The main window (`MainView`) shows the queue in a
  sidebar and keeps a `ReviewModel` for each PR it has shown; Open in New Window puts a review in a `ReviewWindow`.
- **One key handler per window.** `KeyRouter` gives each window a single `commandHandler`. A window showing several
  things (the main window) decides who gets each key, by focus; views inside it don't register their own.
- **Never crash on GitHub data.** Optional fields decode as optionals, unknown enum values fall back to a default,
  and failures become a message in the UI.

### Commands and keys

Every user action is a `CommandID`, so menus, vim-style keys and `config.toml` stay in step. To add one:

1. Add a case with its config name (kebab-case raw value) and a `title` in `CommandID.swift`.
2. Give it default keys in `Keymap.defaults`: a menu chord (needs ⌘, ⌃ or ⌥) and/or vim-style keys.
   Check `shadowingProblems()` stays empty; the `defaultsMatchSequences` test enforces this.
3. Handle it in `ReviewModel.perform(_:)` or `GlobalCommands.perform`. Return `false` when it doesn't apply,
   so the key falls through to the focused view.
4. Add it to the menus in `MaserCommands` if it's useful there.
5. Update the keyboard table in `README.md`, plus `KeyHintBar` if it's a main Files-tab key.

Vim-style keys are paused while a text field or editor has focus. Esc leaves a multi-line editor.

### Settings

Plain settings in `config.toml` (anything that isn't a key binding) go in `Settings` in MaserCore, in a table named
for the area: `[diff]`, `[github]`. Add the field with its default, read it in `Settings.load(toml:)` (report bad
values in `problems`), list it commented out in `Settings.template`, and document it in the README. `ConfigStore`
publishes the loaded `settings` to the app.

## Documentation and comments

Swift's equivalent of a docstring is a **documentation comment**: `///` lines directly above a declaration.
Xcode shows them in Quick Help, and DocC can build reference docs from them. Write them in Markdown.

### File headers

Every file starts with a `//` header comment, before the imports. It summarizes the file in one line, then explains in a
short paragraph what lives there and how it fits into the app. Swift has no file-level docstring, so this plays that role.
It must be `//` and not `///`, because `///` would attach to the first import.

```swift
// The vim-style key router for review windows.
//
// Watches key-down events app-wide, turns plain keystrokes (and multi-key sequences like `g g`) into commands using the
// current keymap, and hands them to the window's command handler. Menu shortcuts (⌘ chords) are left to the menu bar.

import AppKit
```

### Doc comments

Every type, function, initializer and subscript gets a `///` doc comment, at every access level including `private`.
So do enum cases and properties whose meaning isn't obvious from the name and type, and every public property.

```swift
/// Posts a comment to the PR's conversation.
///
/// GitHub renders the Markdown; the reply appears after the next overview load.
///
/// - Parameters:
///   - pr: The pull request to comment on.
///   - body: The comment's Markdown source.
/// - Throws: `GitHubCLIError` if `gh` fails, for example when the PR is locked.
public func addComment(to pr: PullRequest, body: String) async throws
```

- Start with a **one-line summary** sentence ending in a period, then a blank `///` line before any more detail.
- Use `- Parameters:`, `- Returns:` and `- Throws:` whenever a function has parameters, a return value or errors whose
  meaning isn't obvious from the summary. Leave them out for trivial cases (`init(pr:)` storing a value).
- Describe what it does and promises, not how. Implementation notes go in `//` comments inside the body.
- Refer to code with backticks: ``` `ReviewThread` ```, ``` `perform(_:)` ```.
- **Exempt:** members whose meaning a protocol already fixes, such as `var body` in a SwiftUI view, `makeNSView`,
  `init(from:)`, `encode(to:)`, delegate callbacks and `description`. Document them only when they do something
  surprising. Test functions with self-explanatory names are also exempt; give each test suite a doc comment.

`swift format lint` enforces doc comments on public declarations and the one-line summary everywhere. The rest is
enforced in review.

### Inline comments

- Use `//` comments in bodies to explain **why**: a GitHub quirk, a workaround, a non-obvious constraint.
  Don't narrate what the next line does.
- Keep them short, and put them on their own line above the code. A trailing comment is fine only for a brief note.
- `// MARK: - Section` groups related members in long types.
- Don't leave commented-out code or `TODO`s without context. Write `// TODO(#issue): …`, or open an issue.

## Swift style

- Formatting comes from `swift format`, using `.swift-format`: 4-space indents and 130 columns.
  Run `scripts/check` before committing.
- Swift 6 language mode with strict concurrency. UI state is `@MainActor`; work that runs a subprocess is `@concurrent`.
  Don't silence concurrency errors with `@unchecked Sendable` or `nonisolated(unsafe)` without a comment saying why it's safe.
- Use the narrowest access level: `private` by default, `internal` for app-wide use, `public` only for
  MaserCore API that the app uses.
- Prefer value types (`struct`, `enum`) for models; use `final class` only for identity or shared mutable state.
- Name things for what they mean in review terms: `ReviewThread`, `CommentTarget`, not `Item` or `Data2`.
- No force unwraps (`!`) on data from outside the app. Within code where an invariant guarantees the value,
  add a comment stating the invariant.
- User-facing errors are short, specific sentences. Show the message from `gh` where it helps.

## Requirements, risks and verification

Maser is run as if it were regulated software, for practice. `docs/design/` holds the user needs, requirements, risk
file, usability file and traceability, modeled on IEC 62304, ISO 14971 and IEC 62366. `docs/verification/` holds dated
verification records. See `docs/design/README.md` for the ID scheme.

- A PR that changes behavior updates the affected requirements, and the risk file if a hazard or control changes, in
  the same PR. The PR description names the IDs it touches.
- A new requirement says how it will be verified. A risk control that isn't built yet is a `Proposed` requirement
  with an issue.
- Checks you run by hand or with a one-off script go in a verification record. Prefer making them repeatable tests.
- `scripts/check` runs `maser-trace`, which fails on a broken link or a stale generated table. Fix the documents it
  points at, then run `swift run maser-trace --write`.

## Tests

- Every MaserCore change comes with Swift Testing tests (`@Test`, `#expect`, `#require`).
- Name each test with the requirements it verifies: `@Test("REQ-QUE-002: Keeps each PR in its first section")`,
  and cite the test from those requirements in `docs/design/requirements.md`. `maser-trace` checks both directions. A
  test that verifies no requirement means a requirement is missing: add it.
  Use realistic fixtures: the JSON shapes `gh` actually returns.
- Views aren't unit tested, so keep their logic thin. UI behavior that unit tests can't reach (keys, focus, panes,
  layout) gets a UI scenario in `Sources/Maser/UIScenarios.swift`, titled with its requirements like a test and cited
  as `UI:name`; see `Tests/UIScenarios/README.md`. Run `scripts/check-ui` before merging, and say in the PR what
  still wasn't checked (mouse clicks, visual layout).
- Inside `#expect`, avoid calling closures that rethrow (`allSatisfy`, `contains(where:)`): bind the result to a
  `let` first. The macro mis-handles them.

## Git and PRs

- Never commit to `main`. Use a branch and a PR, even for small changes; the PR is where review happens, often in Maser itself.
- Keep each PR to one concern. Put mechanical changes (formatting, renames) in their own commit.
- Commit messages: a short imperative subject (≤ 72 chars), a blank line, then a body explaining what changed and why.
  Commits written with an agent end with a `Co-Authored-By:` trailer.
- PR descriptions have **Summary**, **Implementation notes** (when useful) and **Testing** sections.
  The Testing section lists what ran (`scripts/check`, live tests) and what wasn't checked by hand.
- Reply to review comments on the PR, saying what changed and in which commit.
