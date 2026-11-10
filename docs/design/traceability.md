# Traceability

The tables between `trace:begin` and `trace:end` markers are generated from the other design documents by
`swift run maser-trace --write`. Don't edit them by hand. `scripts/check` runs `maser-trace`, which fails if they're
out of date, or if any link between needs, requirements, risks, controls, tests and verification records is broken.
[README.md](README.md#checking-traceability) lists the rules it enforces.

## User needs to requirements

Every user need must have at least one implemented requirement.

<!-- trace:begin needs-to-requirements -->
| Need | Implemented requirements | Proposed |
| --- | --- | --- |
| UN-1 | REQ-QUE-001, REQ-QUE-002, REQ-QUE-003, REQ-QUE-004, REQ-QUE-006, REQ-QUE-007, REQ-WIN-001, REQ-WIN-005, REQ-WIN-006 | — |
| UN-2 | REQ-GH-003, REQ-GH-004, REQ-OVR-001, REQ-OVR-003, REQ-DIF-008 | — |
| UN-3 | REQ-GH-003, REQ-DIF-001, REQ-DIF-002, REQ-DIF-003, REQ-DIF-004 | REQ-CMT-007 |
| UN-4 | REQ-WIN-004, REQ-OVR-004, REQ-DIF-003, REQ-DIF-008, REQ-CMT-001, REQ-CMT-002, REQ-CMT-003, REQ-CMT-005, REQ-CMT-006 | — |
| UN-5 | REQ-QUE-007, REQ-WIN-002, REQ-WIN-003, REQ-DIF-006, REQ-KEY-001, REQ-KEY-002, REQ-KEY-003, REQ-KEY-004, REQ-KEY-005 | — |
| UN-6 | REQ-KEY-005, REQ-CFG-001, REQ-CFG-002, REQ-CFG-003, REQ-CFG-004, REQ-CFG-005 | — |
| UN-7 | REQ-GH-002, REQ-GH-006, REQ-CFG-005, REQ-PLT-001, REQ-PLT-002 | — |
| UN-8 | REQ-GH-001, REQ-WIN-002, REQ-OVR-002, REQ-CMT-005 | REQ-CMT-007, REQ-CMT-009 |
| UN-9 | REQ-WIN-007, REQ-CMT-004 | REQ-CMT-008 |
| UN-10 | REQ-GH-005, REQ-QUE-005, REQ-WIN-001, REQ-DIF-005, REQ-DIF-007, REQ-PLT-003 | — |
<!-- trace:end needs-to-requirements -->

## Hazards to controls to requirements

The requirements listed are those that implement each hazard's controls, as the controls table in
[risk-management.md](risk-management.md#risk-controls) gives them.

<!-- trace:begin hazards-to-controls -->
| Hazard | Harms | Controls | Requirements | Residual |
| --- | --- | --- | --- | --- |
| HAZ-01 | H1 | RC-01, RC-02, RC-03 | REQ-DIF-001, REQ-GH-003, REQ-OVR-001, REQ-DIF-002 | S4 P1 Medium |
| HAZ-02 | H1, H6 | RC-04, RC-17 | REQ-CMT-007 (proposed), REQ-OVR-003, REQ-WIN-001 | S4 P3 High: open |
| HAZ-03 | H6 | RC-05 | REQ-DIF-003, REQ-CMT-005 | S3 P1 Low |
| HAZ-04 | H2, H6 | RC-06, RC-12 | REQ-WIN-002, REQ-WIN-003, REQ-KEY-002, REQ-KEY-003, REQ-CMT-009 (proposed) | S3 P2 Medium |
| HAZ-05 | H2, H1 | RC-07, RC-12 | REQ-CMT-003, REQ-CMT-009 (proposed) | S4 P1 Medium |
| HAZ-06 | H3 | RC-08 | REQ-CMT-004 | S2 P1 Low |
| HAZ-07 | H3 | RC-09, RC-14, RC-10 | REQ-WIN-007, REQ-GH-004, REQ-QUE-004, REQ-CMT-008 (proposed) | S2 P3 Medium: open until RC-10 |
| HAZ-08 | H4 | RC-11 | REQ-GH-001 | S4 P1 Medium |
| HAZ-09 | H4 | RC-16 | REQ-OVR-002 | S4 P1 Medium |
| HAZ-10 | H2 | RC-12 | REQ-CMT-009 (proposed) | S3 P3 Medium: open |
| HAZ-11 | H1 | RC-17 | REQ-OVR-003, REQ-WIN-001 | S3 P2 Medium |
| HAZ-12 | H5 | RC-15 | REQ-GH-005 | S1 P2 Low |
| HAZ-13 | H4 | RC-13 | REQ-GH-002 | S4 P1 Medium |
| HAZ-14 | H1 | RC-02 | REQ-GH-003, REQ-OVR-001 | S3 P1 Low |
| HAZ-15 | H2 | RC-19 | — | S3 P1 Low |
| HAZ-16 | H2 | RC-18 | REQ-CFG-002 | S3 P1 Low |
| HAZ-17 | H6 | RC-01, RC-20 | REQ-DIF-001, REQ-CMT-001 | S3 P1 Low |
<!-- trace:end hazards-to-controls -->

## Verification coverage

Each requirement is counted by the strongest verification its "Verified by" cell cites. Offline unit tests count
highest, then live GitHub tests, then a verification record or use, then inspection.

<!-- trace:begin coverage -->
| Coverage | Count | Requirements (REQ-…) |
| --- | --- | --- |
| Unit tests, fully | 15 | GH-003, GH-004, QUE-001, QUE-002, QUE-003, QUE-004, OVR-001, DIF-001, DIF-002, CMT-001, KEY-001, CFG-002, CFG-003, CFG-004, CFG-005 |
| Unit tests, partly (the rest is a gap) | 8 | GH-002, GH-006, QUE-007, OVR-004, DIF-003, DIF-004, DIF-006, DIF-008 |
| UI scenarios (no unit tests) | 6 | WIN-001, WIN-003, WIN-007, KEY-002, KEY-003, KEY-004 |
| Live GitHub tests only | 4 | DIF-007, CMT-002, CMT-005, CMT-006 |
| A one-off scripted run or use (not repeatable) | 2 | WIN-006, DIF-005 |
| Inspection only | 6 | GH-001, GH-005, OVR-002, CMT-004, PLT-001, PLT-002 |
| None yet | 10 | QUE-005, QUE-006, WIN-002, WIN-004, WIN-005, OVR-003, CMT-003, KEY-005, CFG-001, PLT-003 |
| Proposed (not built) | 3 | CMT-007, CMT-008, CMT-009 |

54 requirements: 51 implemented and 3 proposed.
<!-- trace:end coverage -->

Most of the "one-off", "inspection only" and "none yet" rows have UI scenarios planned (`UI:…` after `Gap` in
requirements.md). Several implement risk controls (RC-06, RC-07, RC-08, RC-16, RC-17), so writing those scenarios matters for
risk as well as for coverage.

## Next

1. **Proposed controls:** build RC-04 (#18), RC-12 (#20) and RC-10 (#19), in that order of residual risk, each with
   its planned scenario.
2. **More UI scenarios:** the planned ones for risk controls first: UI:finish-review-defaults (RC-07),
   UI:discard-confirms (RC-08), UI:link-opens-browser (RC-16), UI:open-pr-marker (RC-06).
