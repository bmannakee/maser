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
| UN-1 | REQ-QUE-001, REQ-QUE-002, REQ-QUE-003, REQ-QUE-004, REQ-QUE-006, REQ-QUE-007, REQ-QUE-008, REQ-QUE-009, REQ-WIN-001, REQ-WIN-005, REQ-WIN-006, REQ-WIN-008 | — |
| UN-2 | REQ-GH-003, REQ-GH-004, REQ-OVR-001, REQ-OVR-003, REQ-DIF-008 | — |
| UN-3 | REQ-GH-003, REQ-DIF-001, REQ-DIF-002, REQ-DIF-003, REQ-DIF-004, REQ-DIF-009, REQ-DIF-010, REQ-DIF-011, REQ-CMT-007, REQ-AGT-012, REQ-CNV-003, REQ-CNV-004, REQ-CNV-005 | — |
| UN-4 | REQ-WIN-004, REQ-OVR-004, REQ-DIF-003, REQ-DIF-008, REQ-CMT-001, REQ-CMT-002, REQ-CMT-003, REQ-CMT-005, REQ-CMT-006 | — |
| UN-5 | REQ-QUE-007, REQ-QUE-009, REQ-WIN-002, REQ-WIN-003, REQ-DIF-006, REQ-CNV-006, REQ-KEY-001, REQ-KEY-002, REQ-KEY-003, REQ-KEY-004, REQ-KEY-005 | — |
| UN-6 | REQ-KEY-005, REQ-CFG-001, REQ-CFG-002, REQ-CFG-003, REQ-CFG-004, REQ-CFG-005 | — |
| UN-7 | REQ-GH-002, REQ-GH-006, REQ-CFG-005, REQ-PLT-001, REQ-PLT-002 | — |
| UN-8 | REQ-GH-001, REQ-WIN-002, REQ-OVR-002, REQ-CMT-005, REQ-CMT-007, REQ-CMT-009, REQ-AGT-008 | — |
| UN-9 | REQ-WIN-007, REQ-WIN-008, REQ-CMT-004, REQ-CMT-008 | — |
| UN-10 | REQ-GH-005, REQ-GH-007, REQ-QUE-005, REQ-WIN-001, REQ-DIF-005, REQ-DIF-007, REQ-PLT-003 | — |
| UN-15 | REQ-PLT-004 | — |
| UN-11 | REQ-AGT-001, REQ-AGT-002, REQ-AGT-004, REQ-AGT-006, REQ-AGT-009, REQ-AGT-010, REQ-AGT-011 | — |
| UN-12 | REQ-AGT-012, REQ-CNV-001, REQ-CNV-002, REQ-CNV-003, REQ-CNV-004, REQ-CNV-005 | — |
| UN-13 | REQ-AGT-007 | — |
| UN-14 | REQ-AGT-002, REQ-AGT-003, REQ-AGT-004, REQ-AGT-005, REQ-AGT-008, REQ-AGT-010, REQ-CNV-002 | — |
<!-- trace:end needs-to-requirements -->

## Hazards to controls to requirements

The requirements listed are those that implement each hazard's controls, as the controls table in
[risk-management.md](risk-management.md#risk-controls) gives them.

<!-- trace:begin hazards-to-controls -->
| Hazard | Harms | Controls | Requirements | Residual |
| --- | --- | --- | --- | --- |
| HAZ-01 | H1 | RC-01, RC-02, RC-03, RC-21 | REQ-DIF-001, REQ-GH-003, REQ-OVR-001, REQ-DIF-002, REQ-DIF-009 | S4 P1 Medium |
| HAZ-02 | H1, H6 | RC-04, RC-17 | REQ-CMT-007, REQ-OVR-003, REQ-WIN-001 | S4 P1 Medium |
| HAZ-03 | H6 | RC-05 | REQ-DIF-003, REQ-CMT-005 | S3 P1 Low |
| HAZ-04 | H2, H6 | RC-06, RC-12 | REQ-WIN-002, REQ-WIN-003, REQ-KEY-002, REQ-KEY-003, REQ-QUE-009, REQ-CMT-009 | S3 P2 Medium |
| HAZ-05 | H2, H1 | RC-07, RC-12 | REQ-CMT-003, REQ-CMT-009 | S4 P1 Medium |
| HAZ-06 | H3 | RC-08 | REQ-CMT-004 | S2 P1 Low |
| HAZ-07 | H3 | RC-09, RC-14, RC-10 | REQ-WIN-007, REQ-GH-004, REQ-QUE-004, REQ-CMT-008 | S2 P1 Low |
| HAZ-08 | H4 | RC-11 | REQ-GH-001 | S4 P1 Medium |
| HAZ-09 | H4 | RC-16 | REQ-OVR-002 | S4 P1 Medium |
| HAZ-10 | H2 | RC-12 | REQ-CMT-009 | S3 P2 Medium |
| HAZ-11 | H1 | RC-17 | REQ-OVR-003, REQ-WIN-001 | S3 P2 Medium |
| HAZ-12 | H5 | RC-15, RC-31 | REQ-GH-005, REQ-GH-007 | S1 P1 Low |
| HAZ-13 | H4 | RC-13 | REQ-GH-002 | S4 P1 Medium |
| HAZ-14 | H1 | RC-02 | REQ-GH-003, REQ-OVR-001 | S3 P1 Low |
| HAZ-15 | H2 | RC-19 | — | S3 P1 Low |
| HAZ-16 | H2 | RC-18 | REQ-CFG-002 | S3 P1 Low |
| HAZ-17 | H6 | RC-01, RC-20 | REQ-DIF-001, REQ-CMT-001 | S3 P1 Low |
| HAZ-18 | H1 | RC-29, RC-30, RC-25 | REQ-CNV-003, REQ-CNV-004, REQ-CNV-005, REQ-AGT-006 | S4 P2 Medium |
| HAZ-19 | H2, H6 | RC-26, RC-04, RC-12 | REQ-AGT-007, REQ-CMT-007, REQ-CMT-009 | S3 P1 Low |
| HAZ-20 | H1, H2, H7 | RC-22, RC-26, RC-27, RC-29 | REQ-AGT-002, REQ-AGT-003, REQ-AGT-008, REQ-AGT-007, REQ-AGT-010, REQ-CNV-003, REQ-CNV-004 | S4 P2 Medium |
| HAZ-21 | H7 | RC-24 | REQ-AGT-005 | S3 P1 Low |
| HAZ-22 | H3, H2 | RC-23, RC-22 | REQ-AGT-004, REQ-AGT-002, REQ-AGT-003, REQ-AGT-008 | S3 P1 Low |
| HAZ-23 | H4 | RC-22 | REQ-AGT-002, REQ-AGT-003, REQ-AGT-008 | S4 P1 Medium |
| HAZ-24 | H4, H7 | RC-28 | REQ-CNV-002 | S4 P1 Medium |
| HAZ-25 | H1 | RC-25 | REQ-AGT-006 | S4 P1 Medium |
| HAZ-26 | H1 | RC-32, RC-34 | REQ-DIF-010, REQ-DIF-011 | S4 P1 Medium |
| HAZ-27 | H6 | RC-33 | REQ-QUE-008 | S3 P1 Low |
<!-- trace:end hazards-to-controls -->

## Verification coverage

Each requirement is counted by the strongest verification its "Verified by" cell cites. Offline unit tests count
highest, then live GitHub tests, then a verification record or use, then inspection.

<!-- trace:begin coverage -->
| Coverage | Count | Requirements (REQ-…) |
| --- | --- | --- |
| Unit tests, fully | 34 | GH-003, GH-004, GH-007, QUE-001, QUE-002, QUE-003, QUE-004, QUE-008, WIN-008, OVR-001, DIF-001, DIF-002, CMT-001, CMT-007, CMT-008, AGT-001, AGT-002, AGT-003, AGT-004, AGT-005, AGT-006, AGT-008, AGT-009, AGT-010, AGT-011, CNV-001, CNV-002, CNV-003, CNV-004, KEY-001, CFG-002, CFG-003, CFG-004, CFG-005 |
| Unit tests, partly (the rest is a gap) | 11 | GH-002, GH-006, QUE-007, QUE-009, OVR-004, DIF-003, DIF-004, DIF-006, DIF-008, CMT-009, AGT-007 |
| UI scenarios (no unit tests) | 10 | WIN-001, WIN-003, WIN-007, DIF-009, DIF-011, CNV-005, CNV-006, KEY-002, KEY-003, KEY-004 |
| Live GitHub tests only | 5 | DIF-007, CMT-002, CMT-005, CMT-006, AGT-012 |
| A one-off scripted run or use (not repeatable) | 3 | WIN-006, DIF-005, DIF-010 |
| Inspection only | 7 | GH-001, GH-005, OVR-002, CMT-004, PLT-001, PLT-002, PLT-004 |
| None yet | 10 | QUE-005, QUE-006, WIN-002, WIN-004, WIN-005, OVR-003, CMT-003, KEY-005, CFG-001, PLT-003 |
| Proposed (not built) | 0 | — |

80 requirements: 80 implemented and 0 proposed.
<!-- trace:end coverage -->

Most of the "one-off", "inspection only" and "none yet" rows have UI scenarios planned (`UI:…` after `Gap` in
requirements.md). Several implement risk controls (RC-06, RC-07, RC-08, RC-16, RC-17), so writing those scenarios matters for
risk as well as for coverage.

## Next

1. **More UI scenarios:** the planned ones for risk controls first: UI:finish-review-defaults (RC-07),
   UI:discard-confirms (RC-08), UI:link-opens-browser (RC-16), UI:open-pr-marker (RC-06).
2. **Review agent (#32):** built and evaluated on 2026-11-12. Before relying on it to review regulated software, run
   HRUS-9 to HRUS-12 with the user (usability.md), and add evaluation cases as real PRs show where it goes wrong.
