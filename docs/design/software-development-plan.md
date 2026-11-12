# Software development plan

Modeled on IEC 62304 §5.1. Draft 1, 2026-11-03.

## Scope and intended use

**Maser is a native macOS app for reviewing GitHub pull requests.** It lists the PRs needing the user's attention,
shows a PR's conversation, status and changes, and lets the user comment on lines, reply to threads, and submit a
review with a verdict. It does everything through the user's own `gh` command-line client.

**Planned (#32): a review agent.** A conversation with an agent about the open PR, which can read the PR's repository,
add comments to the user's pending review, and draw diagrams of the change on a canvas. It runs through the user's own
`claude` command-line client, as GitHub access runs through `gh`. The agent's output is an aid to reading the change,
not a substitute for it: the diff stays the thing reviewed. See [review-agent.md](review-agent.md).

**Intended user:** one experienced software engineer, the author, who works mostly from the keyboard with vim-style
keys. See [usability.md](usability.md) for the full use specification.

**Intended use environment:**

- The user's personal Mac: macOS 27.
- An enterprise-managed work Mac: macOS 26, with only the Xcode command-line tools, and no unsigned or quarantined
  apps.
- github.com, and potentially GitHub Enterprise hosts.

**Why it matters:** at work, Maser will be used to review software that may itself be regulated. A review decision
made on wrong or incomplete information can let a defect through. Code review isn't the only control on that software,
but Maser should not weaken it. This is the main source of harm in the [risk file](risk-management.md).

## Software safety classification

**Class B, for practice.**

IEC 62304 classifies by the worst harm that a failure of the software could contribute to, after external risk
controls. Maser can't injure anyone directly. A failure could, however, contribute to a defect in reviewed software
going unnoticed, as described in `H1` in the risk file. Other controls on that software lie outside Maser: other
reviewers, testing, and the work organization's own quality system.

On a strict reading that makes Maser Class A. It is treated as **Class B** to practice the extra activities Class B
requires:

- architectural design documentation;
- documented software units with verification;
- integration testing;
- regression testing.

## Lifecycle

| Activity | How it's done |
| --- | --- |
| Planning | This plan; GitHub issues for planned work |
| Requirements | [requirements.md](requirements.md), updated in the PR that changes behavior |
| Architecture | `AGENTS.md` ("Architecture"): `MaserCore` (testable logic, GitHub access) and `Maser` (views, view models) |
| Detailed design | Doc comments on every type and function, as `AGENTS.md` requires; file header comments |
| Implementation | Swift 6, strict concurrency; conventions in `AGENTS.md`; formatting enforced by `swift format` |
| Unit verification | Swift Testing in `MaserCoreTests`; `scripts/check` runs them on every commit |
| Integration verification | Live tests against GitHub (`MASER_LIVE_TESTS=1`; `MASER_LIVE_WRITE_TESTS=1`, limited to bmannakee/maser#1). |
| System verification | Scripted UI scenarios against a fake `gh` (`scripts/check-ui`); verification records in `docs/verification/` |
| Validation | Use by the intended user against [user-needs.md](user-needs.md), recorded per release |
| Release | `scripts/bundle` builds `Maser.app`. Planned: a tagged release and a release record listing what was verified, with known anomalies. |

Every change goes through a branch and a PR. Nothing is committed to `main` directly. Review usually happens in Maser
itself. PR descriptions follow `AGENTS.md`:

- **Summary**
- **Implementation notes**
- **Testing**, including what wasn't checked by hand

## SOUP (software of unknown provenance)

| Item | Version | Use | Known risks and how they're handled |
| --- | --- | --- | --- |
| GitHub CLI (`gh`) | 2.102.1 at home; work version unknown | All GitHub access, authentication and the token | Output format changes break decoding. Handled by decoding defensively (`REQ-GH-004`), live tests, and showing failures as messages. |
| GitHub GraphQL and REST APIs | — | Data and mutations | Quiet failures. A comment on a line outside the diff returns a null thread (`HAZ-03`). Lists are capped (`HAZ-14`). |
| TOMLDecoder | 0.4.5 (`Package.resolved`) | Parsing `config.toml` | Decode errors surface as `TOMLError`; the config banner reports them (`REQ-CFG-002`). |
| SwiftUI and AppKit | macOS 26 / 27 SDKs | UI | Layout loops crashed the app when split views were nested, or with an inspector beside the file tree (`HAZ-07`, V5–V7). Focus doesn't always move when asked (V9). |
| WebKit | macOS SDK | Rendering the conversation HTML | Untrusted content. Page JavaScript is disabled (`REQ-OVR-002`). |
| Claude Code (`claude`), planned | 2.1.322 at home; work version unknown | The review agent (#32): the agent loop, file tools, the model connection and its login | Its command-line options and stream-json output can change; pinned by checking the version and by a fake for the UI scenarios. Loads settings and hooks from the working directory unless told not to (`HAZ-23`). |
| Claude models, planned | Whatever `claude` is set to use | The agent's answers, comments and diagrams | Output can be wrong or steered by the content it reads (`HAZ-18`, `HAZ-20`). |
| Mermaid and Graphviz (Viz.js), planned | To be chosen and pinned | Rendering diagrams on the canvas (#32) | Parser bugs and script in diagram source (`HAZ-24`). Bundled, never fetched. |
| git, planned | Xcode command-line tools | The agent's checkout (#32) | Must never write to the user's clone (`HAZ-22`). |
| Swift toolchain | 6.2 minimum; 6.4 at home | Build | The work Mac's version is unknown, so the minimum is checked by building against `swift-tools-version: 6.2`. |

## Configuration management

- **Source:** git, at `github.com/bmannakee/maser`.
- **Dependencies:** pinned by `Package.resolved`.
- **Build identity:** the bundle's version is `git describe --tags --always` at build time. A build from uncommitted
  changes reports the last commit. That happened during verification on 2026-11-03, so releases must be built from a
  clean tree.

## Problem resolution

Problems are GitHub issues. An issue that turns out to be a risk, such as a crash or a wrong action, is linked to its
hazard in the risk file, and the PR that fixes it updates the risk file.

## Verification strategy

| Level | What | When |
| --- | --- | --- |
| Unit | `MaserCoreTests` | Every commit (`scripts/check`) |
| Integration, read | Live read tests | Before merging changes to GitHub access |
| Integration, write | Live write tests on PR #1 only | Before merging changes to write paths |
| System (UI) | Scripted scenarios with a fake `gh` (`scripts/check-ui`, see `Tests/UIScenarios/README.md`) | Every PR that changes the app, on an unlocked Mac |
| Validation | Use by the intended user | Before each release |

A requirement that can't be tested automatically says so and names its inspection or manual check.
