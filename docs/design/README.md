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
| `KEY` | Keyboard |
| `CFG` | Configuration |
| `PLT` | Platform and packaging |

Verification references use these forms:

| Reference | Meaning |
| --- | --- |
| `T:Suite.test` | Unit test in `MaserCoreTests` |
| `L:Suite.test` | Live test against GitHub (`MASER_LIVE_TESTS` or `MASER_LIVE_WRITE_TESTS`) |
| `UI:scenario` | Scripted UI scenario. The harness doesn't exist yet, so these are planned. |
| `V-…/Vn` | A check in a verification record |
| `I:` | Inspection of the code or the product |
| `U:` | Use by the user, recorded in a verification record or a PR |

## Changing these documents

- A PR that changes behavior updates the affected requirements, the risk file if a hazard or control changes, and the
  traceability, in the same PR. Its description says which IDs it touches.
- A new requirement says how it will be verified before it is built.
- A risk control that isn't built yet is a requirement with status `Proposed` and a GitHub issue.
- The traceability matrix is maintained by hand for now. The plan is a checker in `scripts/check` that builds it from
  these documents and the tests, and fails on broken or missing links.
