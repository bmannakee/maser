# Risk management file

Modeled on ISO 14971. Draft 1, 2026-11-03, covering `main` as of PR #16.

## Scope

This file covers Maser as described in the [software development plan](software-development-plan.md): reviewing
GitHub pull requests on macOS through `gh`. The risks are those of the review tool itself, not of the software being
reviewed. That software's own risks are managed by the projects that own it. Maser's part is whether it presents the
change faithfully and acts only as the user intends.

## Harms

| ID | Harm | Severity |
| --- | --- | --- |
| H1 | A defect in reviewed software goes unnoticed and ships, because the review rested on wrong or incomplete information, or approved code the reviewer never saw. | S4 Critical |
| H2 | An action the user didn't intend appears under their name, such as an approval, a "Request changes" or a comment, and misleads colleagues or becomes part of a record. | S3 Serious |
| H3 | Review work the user wrote is lost and has to be redone, or is skipped. | S2 Minor |
| H4 | The user's GitHub credentials, or their account, are compromised. | S4 Critical |
| H5 | Time is lost to a hang, crash or confusing behavior, with no lasting effect. | S1 Negligible |
| H6 | Feedback goes to the wrong place (a different line, file or PR), or never arrives, and the author acts on it wrongly or never sees it. | S3 Serious |

## Risk estimation

**Severity:**

| Level | Name | Meaning |
| --- | --- | --- |
| S1 | Negligible | Inconvenience |
| S2 | Minor | Work redone |
| S3 | Serious | A wrong or misleading action in a shared record, which others may act on |
| S4 | Critical | A defect ships, or the account is compromised |

**Probability of the harm**, per use of the feature over the tool's life:

| Level | Name | Meaning |
| --- | --- | --- |
| P1 | Improbable | Not expected to happen |
| P2 | Remote | Could happen, but not expected |
| P3 | Occasional | Expected to happen now and then |
| P4 | Probable | Expected often |
| P5 | Frequent | Routine |

Software failures can't be given meaningful numeric probabilities, as IEC 62304 notes. These estimates are
qualitative. They are based on how often the hazardous situation arises and how likely it is to lead to the harm.
Where a failure has actually been seen, such as a crash or a focus bug during the 2026-11-03 sessions, the estimate is
at least P3 before controls.

**Acceptability.** Each cell is the risk level for a severity and probability:

|  | S1 | S2 | S3 | S4 |
| --- | --- | --- | --- | --- |
| **P5** | Medium | High | High | High |
| **P4** | Low | Medium | High | High |
| **P3** | Low | Medium | Medium | High |
| **P2** | Low | Low | Medium | Medium |
| **P1** | Low | Low | Low | Medium |

The levels mean:

- **Low:** acceptable.
- **Medium:** acceptable only once reduced as far as practicable, with the reason recorded.
- **High:** not acceptable. The feature needs further controls before it can be relied on.

## Hazard analysis

Each row lists:

- the hazard and the sequence of events that leads to harm;
- the risk before controls (initial) and after them (residual);
- the controls, which are detailed in the next section.

| ID | Hazard and sequence of events | Harm | Initial | Controls | Residual |
| --- | --- | --- | --- | --- | --- |
| HAZ-01 | The diff Maser shows doesn't match the PR: a parse error, a truncated list, a mangled path, or a full-file merge that doesn't fit. The user approves code they didn't actually see. | H1 | S4 P3 **High** | RC-01, RC-02, RC-03 | S4 P1 Medium |
| HAZ-02 | The PR's head moves (a new push) after Maser loaded the diff. A line comment posted with old line numbers lands on a different line of the new head, or an approval covers commits the user never saw. Maser neither pins the commit nor warns. | H1, H6 | S4 P3 **High** | RC-04 (*proposed*), RC-17 (partial) | **S4 P3 High: open** |
| HAZ-03 | The user comments on a line that's only shown in the full-file view. GitHub silently creates nothing, and the user believes they raised the issue. | H6 | S3 P4 **High** | RC-05 | S3 P1 Low |
| HAZ-04 | A key acts somewhere the user didn't expect. For example, `S`, `c` or Return acts on the open PR while the user is looking at a different, highlighted PR in the queue, or on the wrong pane. Several focus bugs of this kind were found on 2026-11-03 (V8–V10). | H2, H6 | S3 P4 **High** | RC-06, RC-12 (*proposed*) | S3 P2 Medium |
| HAZ-05 | The wrong verdict is submitted, such as Approve instead of Comment, or on the wrong PR. | H2, H1 | S4 P2 Medium | RC-07, RC-12 (*proposed*) | S4 P1 Medium |
| HAZ-06 | The user discards a pending review by accident, deleting every draft comment. | H3 | S2 P3 Medium | RC-08 | S2 P1 Low |
| HAZ-07 | Maser crashes, or the user quits it, while unsent text is in a comment box or the review summary. The text is only in memory, so it's lost. Four crashes happened on 2026-11-03 (V5). | H3 | S2 P4 Medium | RC-09, RC-14, RC-10 (*proposed*) | S2 P3 Medium: open until RC-10 |
| HAZ-08 | The GitHub token leaks through Maser: logged, stored, or sent somewhere. | H4 | S4 P2 Medium | RC-11 | S4 P1 Medium |
| HAZ-09 | Malicious content in a PR's description or comments runs script in Maser, or leads the user to a phishing page. | H4 | S4 P2 Medium | RC-16 | S4 P1 Medium |
| HAZ-10 | `gh` is signed in to a different account than the user expects (personal versus work), so comments and reviews are posted as the wrong identity. Nothing in Maser shows the account. | H2 | S3 P3 Medium | RC-12 (*proposed*) | **S3 P3 Medium: open** |
| HAZ-11 | Maser shows stale status (checks, mergeability, new comments), and the user decides on information that has since changed. | H1 | S3 P3 Medium | RC-17 | S3 P2 Medium |
| HAZ-12 | A `gh` call hangs, and Maser stops responding or never finishes loading. | H5 | S1 P3 Low | RC-15 | S1 P2 Low |
| HAZ-13 | Maser runs a `gh` other than the user's own, from a planted binary on the search path or a wrong configured path. | H4 | S4 P1 Medium | RC-13 | S4 P1 Medium |
| HAZ-14 | GitHub returns a capped list (100 items) and Maser shows it as complete, hiding a failing check, a blocking review or a comment. | H1 | S3 P3 Medium | RC-02 | S3 P1 Low |
| HAZ-15 | Development: a live write test posts to a real PR other than the test PR. | H2 | S3 P2 Medium | RC-19 | S3 P1 Low |
| HAZ-16 | A mistake in `config.toml` silently changes or removes bindings, so keys act unexpectedly (leading to HAZ-04). | H2 | S3 P3 Medium | RC-18 | S3 P1 Low |
| HAZ-17 | A line comment is attached to the wrong line or side, because a cursor line is mapped to GitHub's line numbers incorrectly, for example for a range across hunks or sides. | H6 | S3 P3 Medium | RC-01, RC-20 | S3 P1 Low |

## Risk controls

The verification for each control is the verification of its requirements, in [requirements.md](requirements.md).

| ID | Control | Type | Requirements | Status |
| --- | --- | --- | --- | --- |
| RC-01 | The diff parser is verified against the diff shapes GitHub produces: renames, binary files, the no-newline marker, quoted paths. | Inherent safety by design | REQ-DIF-001 | Implemented |
| RC-02 | Every paged list is fetched in full, and truncation is detected rather than shown as complete. | Inherent safety by design | REQ-GH-003, REQ-OVR-001 | Implemented |
| RC-03 | A full file is merged only if its contents match the diff; otherwise Maser shows an error. | Protective measure | REQ-DIF-002 | Implemented |
| RC-04 | Comments and reviews are pinned to the head commit the user saw, with a warning and a reload when the head has moved. | Protective measure | REQ-CMT-007 | **Proposed** |
| RC-05 | Expanded lines can't take comments, and say why. A comment GitHub doesn't create is shown as an error. | Protective measure | REQ-DIF-003, REQ-CMT-005 | Implemented |
| RC-06 | Key ownership is explicit. The window tracks whether the queue or the review has the keys, the open PR is marked, vim keys pause while typing, and `/` acts only in the queue. | Protective measure | REQ-WIN-002, REQ-WIN-003, REQ-KEY-002, REQ-KEY-003 | Implemented |
| RC-07 | The verdict starts at Comment every time and must be chosen explicitly. Submitting takes a button or ⌘↩ in the sheet. | Protective measure | REQ-CMT-003 | Implemented |
| RC-08 | Discarding a review asks for confirmation, naming the number of drafts it deletes. | Protective measure | REQ-CMT-004 | Implemented |
| RC-09 | The UI avoids the layouts that loop AppKit's constraint updates (nested split views, an inspector beside the file tree), and a stress scenario checks for it. | Inherent safety by design | REQ-WIN-007 | Implemented; scenario planned |
| RC-10 | Unsent text is saved locally as it's typed, and restored. | Protective measure | REQ-CMT-008 | **Proposed** |
| RC-11 | GitHub access only through `gh`. Maser never handles the token. | Inherent safety by design | REQ-GH-001 | Implemented |
| RC-12 | The PR and the account are named wherever Maser posts. | Information for safety | REQ-CMT-009 | **Proposed** |
| RC-13 | `gh` is found by a fixed, documented search order, or by an explicit configured path. | Protective measure | REQ-GH-002 | Implemented |
| RC-14 | Defensive decoding; failures become messages, per section in the queue. | Protective measure | REQ-GH-004, REQ-QUE-004 | Implemented |
| RC-15 | Subprocesses never block the UI. | Protective measure | REQ-GH-005 | Implemented (only the login-shell lookup has a timeout) |
| RC-16 | Rendered PR content runs no JavaScript, and links open in the default browser. | Inherent safety by design | REQ-OVR-002 | Implemented |
| RC-17 | Data freshness: relative times are refreshed, a PR reloads on return when over 60 s old, and there's a manual refresh (`r`). | Protective measure | REQ-OVR-003, REQ-WIN-001 | Implemented |
| RC-18 | Config problems are reported in a banner and skipped, never silently applied. Shadowed bindings are reported. | Information for safety | REQ-CFG-002 | Implemented |
| RC-19 | Live write tests are hard-coded to bmannakee/maser#1, which `AGENTS.md` requires. | Process control | — (I: `LiveReviewWriteTests`) | Implemented |
| RC-20 | Comment targets are computed from the parsed line numbers on each side, and clipped to one hunk. | Inherent safety by design | REQ-CMT-001 | Implemented |

## Residual risk

The residual risks that are Medium are acceptable only with a reason, recorded here:

- **HAZ-01, HAZ-05, HAZ-08, HAZ-09, HAZ-13:** these are Medium because the harm is Critical, even at Improbable.
  Further reduction would mean independent verification of the diff against the GitHub web view, or of `gh` itself,
  which isn't practicable for a client of `gh`. GitHub's own branch protection and other reviewers remain controls on
  H1.
- **HAZ-04:** Medium until RC-12 names the PR when posting. The key-routing controls (RC-06) are verified only by one
  scripted run so far, so the UI harness should make that run repeatable.
- **HAZ-11:** Medium. A "loaded at" indicator on the Overview would reduce it further. It's recorded as a candidate
  control, not yet a requirement.

The open risks need further controls before Maser is relied on for review at work:

| Hazard | Residual | Needs | Issue |
| --- | --- | --- | --- |
| HAZ-02 | High | RC-04: pin comments and reviews to the commit seen, and warn when the head has moved | #18 |
| HAZ-07 | Medium | RC-10: keep unsent text across crashes and quits | #19 |
| HAZ-10 (and HAZ-04, HAZ-05) | Medium | RC-12: name the PR and account when posting | #20 |
| HAZ-12 | Low (observation) | Timeouts on `gh` calls, which have none today, so a hung `gh` loads forever | #21 |

**Overall residual risk:** not yet acceptable for use at work, because HAZ-02 is High. It is acceptable for personal
use, where reviews carry less weight, provided the user reloads before submitting.

## Production and post-production

Any problem found in use is a GitHub issue. If it reveals a new hazard, or a control that doesn't work, this file is
updated in the PR that fixes it. The 2026-11-03 crashes and focus bugs are recorded this way: as evidence for HAZ-04
and HAZ-07, and through RC-06 and RC-09.
