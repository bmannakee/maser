# Traceability

Draft 1, 2026-11-03. This is maintained by hand for now. The plan is to generate it from the documents and the tests,
and to check it in `scripts/check`; see "Next" below.

## User needs to requirements

| Need | Requirements |
| --- | --- |
| UN-1 Find PRs needing attention | REQ-QUE-001 to 006, REQ-WIN-001, REQ-WIN-005, REQ-WIN-006 |
| UN-2 Read the full context | REQ-GH-003, REQ-GH-004, REQ-OVR-001, REQ-OVR-003 |
| UN-3 See exactly what changed | REQ-GH-003, REQ-DIF-001 to 004, REQ-CMT-007 (proposed) |
| UN-4 Comment and review | REQ-OVR-004, REQ-DIF-003, REQ-CMT-001 to 006, REQ-WIN-004 |
| UN-5 Keyboard, no surprises | REQ-WIN-002, REQ-WIN-003, REQ-DIF-006, REQ-KEY-001 to 005 |
| UN-6 Configure in a dotfile | REQ-CFG-001 to 005, REQ-KEY-005 |
| UN-7 Work Mac | REQ-GH-002, REQ-GH-006, REQ-CFG-005, REQ-PLT-001, REQ-PLT-002 |
| UN-8 Credentials safe; act only as intended | REQ-GH-001, REQ-OVR-002, REQ-WIN-002, REQ-CMT-005, REQ-CMT-007 (proposed), REQ-CMT-009 (proposed) |
| UN-9 Don't lose work | REQ-WIN-007, REQ-CMT-004, REQ-CMT-008 (proposed) |
| UN-10 Quick | REQ-GH-005, REQ-QUE-005, REQ-WIN-001, REQ-DIF-005, REQ-DIF-007, REQ-PLT-003 |

Every user need has at least one implemented requirement.

## Hazards to controls to requirements

| Hazard | Controls | Requirements | Residual |
| --- | --- | --- | --- |
| HAZ-01 | RC-01, RC-02, RC-03 | REQ-DIF-001, REQ-GH-003, REQ-OVR-001, REQ-DIF-002 | Medium |
| HAZ-02 | RC-04, RC-17 | REQ-CMT-007 (proposed), REQ-OVR-003, REQ-WIN-001 | **High, open** |
| HAZ-03 | RC-05 | REQ-DIF-003, REQ-CMT-005 | Low |
| HAZ-04 | RC-06, RC-12 | REQ-WIN-002, REQ-WIN-003, REQ-KEY-002, REQ-KEY-003, REQ-CMT-009 (proposed) | Medium |
| HAZ-05 | RC-07, RC-12 | REQ-CMT-003, REQ-CMT-009 (proposed) | Medium |
| HAZ-06 | RC-08 | REQ-CMT-004 | Low |
| HAZ-07 | RC-09, RC-10 | REQ-WIN-007, REQ-CMT-008 (proposed) | Medium, open |
| HAZ-08 | RC-11 | REQ-GH-001 | Medium |
| HAZ-09 | RC-16 | REQ-OVR-002 | Medium |
| HAZ-10 | RC-12 | REQ-CMT-009 (proposed) | **Medium, open** |
| HAZ-11 | RC-17 | REQ-OVR-003, REQ-WIN-001 | Medium |
| HAZ-12 | RC-15 | REQ-GH-005 | Low |
| HAZ-13 | RC-13 | REQ-GH-002 | Medium |
| HAZ-14 | RC-02 | REQ-GH-003 | Low |
| HAZ-15 | RC-19 | — (process; `AGENTS.md`) | Low |
| HAZ-16 | RC-18 | REQ-CFG-002 | Low |
| HAZ-17 | RC-01, RC-20 | REQ-DIF-001, REQ-CMT-001 | Low |

## Verification coverage

These counts come from [requirements.md](requirements.md), and cover 52 requirements: 49 implemented and 3 proposed. They were
counted by a script that reads the requirements table, which is the first piece of the planned trace checker.

| Coverage | Count | Requirements (REQ-…) |
| --- | --- | --- |
| Unit tests, fully | 14 | GH-003, GH-004, QUE-001, QUE-002, QUE-003, OVR-001, DIF-001, DIF-002, CMT-001, KEY-001, CFG-002, CFG-003, CFG-004, CFG-005 |
| Unit tests, partly (the rest is a gap) | 7 | GH-002, GH-006, QUE-004, OVR-004, DIF-003, DIF-004, DIF-006 |
| Live GitHub tests only | 4 | DIF-007, CMT-005, CMT-006; CMT-002 partly |
| A one-off scripted run or use (not repeatable) | 6 | WIN-003, WIN-006, WIN-007, DIF-005, KEY-003, KEY-004 |
| Inspection only | 6 | GH-001, GH-005, OVR-002, CMT-004, PLT-001, PLT-002 |
| None yet | 12 | QUE-005, QUE-006, WIN-001, WIN-002, WIN-004, WIN-005, OVR-003, CMT-003, KEY-002, KEY-005, CFG-001, PLT-003 |
| Proposed (not built) | 3 | CMT-007, CMT-008, CMT-009 |

Most of the "one-off", "inspection only" and "none yet" rows are planned UI scenarios (`UI:…` in requirements.md).
Several of them implement risk controls (RC-06, RC-07, RC-08, RC-09, RC-16, RC-17), so the UI harness matters for risk as well as
for coverage.

## Next

1. **Trace checker** (`scripts/trace`, run by `scripts/check`):
   - read the ID tables in these documents and the `@Test` names in the tests;
   - fail when an implemented requirement has no verification reference, a risk control has no requirement, a
     reference points at a test or ID that doesn't exist, or a `Proposed` requirement has no issue;
   - generate this file.
2. **Test IDs in tests:** give tests display names that start with their requirement IDs, such as
   `@Test("REQ-QUE-002: …")`, so the checker can map tests to requirements without a separate list.
3. **UI harness:**
   - a debug-only scenario runner (`MASER_UI_SCENARIO=<name>`) that drives the app through its commands and asserts on
     its state, replacing the temporary hook from 2026-11-03;
   - a fake `gh` (selected with `[github] gh`) that replays recorded GitHub responses and records the mutations sent,
     including failures;
   - `scripts/check-ui` to run every scenario.
4. **Proposed controls:** build RC-04, RC-12 and RC-10, in that order of residual risk.
