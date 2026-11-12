# Maser design documentation

This folder is Maser's design history: what the product must do, what could go wrong, and how each part is verified.
It is modeled on the documents a regulated medical device software project keeps, as practice:

- **Software lifecycle:** IEC 62304, including software safety classification and SOUP.
- **Risk management:** ISO 14971.
- **Usability engineering:** IEC 62366-1.

Maser isn't a medical device, and nothing here claims compliance with these standards. They are followed for their
structure and discipline.

**Status: draft 1 (2026-11-03).** This draft covers the features in `main` as of PR #16. It was written after the
features were built, so it describes the current design rather than having driven it. From here on, a change updates
these documents in the same PR.

## Documents

| Document | Model | Contents |
| --- | --- | --- |
| [software-development-plan.md](software-development-plan.md) | IEC 62304 §5.1 | Scope, safety class, lifecycle, SOUP, configuration and problem management, verification strategy |
| [user-needs.md](user-needs.md) | Design inputs (user needs) | What the user needs Maser to do; validation is against these |
| [requirements.md](requirements.md) | IEC 62304 §5.2 | Software requirements, each traced to a need and a verification |
| [risk-management.md](risk-management.md) | ISO 14971 | Harms, hazards, risk estimates, controls and residual risk |
| [usability.md](usability.md) | IEC 62366-1 | Use specification, user interface characteristics tied to safety, hazard-related use scenarios, evaluations |
| [brand.md](brand.md) | Brand | Name, logo, colors and interface guidelines; mirrored by `Sources/Maser/Brand.swift` |
| [review-agent.md](review-agent.md) | Design (planned feature) | The review agent and canvas: architecture, decisions, open questions, verification plan |
| [traceability.md](traceability.md) | Traceability | Needs → requirements → verification, hazards → controls, and the gaps |
| [../verification/](../verification/) | Verification records | Dated records of verification runs |

## Identifiers

IDs are permanent. When an item is withdrawn, it is marked `Withdrawn` rather than deleted or renumbered, so links
from tests, commits and records stay valid.

| Prefix | Item | Example |
| --- | --- | --- |
| `UN-n` | User need | `UN-4` |
| `REQ-AREA-nnn` | Software requirement | `REQ-CMT-001` |
| `H-n` | Harm | `H2` |
| `HAZ-nn` | Hazard (with its sequence of events) | `HAZ-02` |
| `RC-nn` | Risk control measure | `RC-04` |
| `HRUS-n` | Hazard-related use scenario | `HRUS-1` |
| `V-YYYY-MM-DD/Vn` | One check in a verification record | `V-2026-11-03/V10` |

The requirement areas are:

| Area | Covers |
| --- | --- |
| `GH` | GitHub access |
| `QUE` | Queue |
| `WIN` | Main window |
| `OVR` | Overview tab |
| `DIF` | Diff and Files tab |
| `CMT` | Commenting and reviewing |
| `AGT` | Review agent (planned) |
| `CNV` | Canvas for the agent's diagrams (planned) |
| `KEY` | Keyboard |
| `CFG` | Configuration |
| `PLT` | Platform and packaging |

Verification references use these forms:

| Reference | Meaning |
| --- | --- |
| `T:Suite.test` | Unit test in `MaserCoreTests` |
| `L:Suite.test` | Live test against GitHub (`MASER_LIVE_TESTS` or `MASER_LIVE_WRITE_TESTS`) |
| `UI:scenario` | Scripted UI scenario in `Sources/Maser/UIScenarios.swift`, run by `scripts/check-ui`. After `Gap`, or in a `Planned` cell, one still to write. |
| `V-…/Vn` | A check in a verification record |
| `I:` | Inspection of the code or the product |
| `U:` | Use by the user, recorded in a verification record or a PR |

## Changing these documents

- A PR that changes behavior updates the affected requirements, the risk file if a hazard or control changes, and the
  traceability, in the same PR. Its description says which IDs it touches.
- A new requirement says how it will be verified before it is built.
- A risk control that isn't built yet is a requirement with status `Proposed` and a GitHub issue.
- `scripts/check` runs `maser-trace`, which checks the rules below. After changing these documents, run
  `swift run maser-trace --write` to regenerate the tables in [traceability.md](traceability.md).

## Checking traceability

`maser-trace` (in `Sources/maser-trace`, with its logic in `Sources/Traceability` and tests in
`Tests/TraceabilityTests`) reads these documents, the tests in `Tests/`, and the records in `docs/verification/`. It
prints each problem as `file:line: message [rule]`, and fails if there are any.

Every test of Maser names the requirements it verifies at the start of its display name, such as
`@Test("REQ-DIF-002, REQ-DIF-006: Matches lines across views")`, and each of those requirements cites the test. The
traceability tool's own tests, in `Tests/TraceabilityTests`, verify the tool rather than Maser, so they don't.
UI scenarios follow the same rule: each one's title starts with the requirements it verifies, such as
`UIScenario("key-routing", "REQ-WIN-003, REQ-KEY-003: …")`, and those requirements cite `UI:key-routing`.



| Rule | Fails when |
| --- | --- |
| `duplicate-id` | An ID is defined in more than one row. |
| `unknown-id` | A design document (other than this README), a test's display name or a UI scenario's title mentions an ID that isn't defined. |
| `requirement-without-need` | A requirement names no user need. |
| `unstated-verification` | A requirement's "Verified by" cell cites nothing (`T:`, `L:`, `V-…`, `I:`, `U:`) and notes no `Gap` or plan. |
| `unknown-test` | A `T:` or `L:` reference names a suite or test that doesn't exist, or cites a live test as `T:` or an offline one as `L:`. |
| `wrong-test-count` | A whole-suite reference says `(all N)` but the suite has a different number of tests. |
| `unknown-record-check` | A `V-YYYY-MM-DD/Vn` reference has no matching `### Vn:` heading in that day's record. |
| `proposed-without-issue` | A `Proposed` or `Planned` requirement's status doesn't name an issue, such as `(#18)`. |
| `control-link-mismatch` | A requirement names a control that doesn't list it, or a control lists a requirement that doesn't name it. |
| `control-status-mismatch` | A control is marked `Proposed` but all its requirements are implemented, or the reverse. |
| `unused-control` | No hazard uses a control. |
| `incomplete-hazard` | A hazard has no harm or no control. |
| `unmet-need` | No implemented requirement serves a user need, unless the need's status is `Planned`. |
| `untracked-open-risk` | A hazard's residual risk is High, or marked open, but the open risks table doesn't list it. |
| `stale-traceability` | A generated section of traceability.md is missing or out of date. |
| `test-claim-mismatch` | A requirement cites a test or UI scenario that doesn't claim the requirement, or a test or scenario claims a requirement that doesn't cite it. A whole-suite reference cites every test in the suite. |
| `untraced-test` | A test outside `Tests/TraceabilityTests` has no requirement ID in its display name, or a UI scenario none in its title. |
| `unknown-scenario` | A `UI:` reference names a scenario that doesn't exist, or a `Gap` lists one that does (cite it instead). |

The rules about tests are checked against the test functions in the source; they don't run the tests. Whether a cited
test passes is up to `swift test`, and for live tests, the live runs.
