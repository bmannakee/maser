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
| H7 | Code or data is disclosed to a third party, here the model provider, that its owner hasn't approved. | S3 Serious |

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
| HAZ-01 | The diff Maser shows doesn't match the PR: a parse error, a truncated list, a mangled path, a full-file merge that doesn't fit, or lines drawn over one another so part of one is hidden. The user approves code they didn't actually see. | H1 | S4 P3 **High** | RC-01, RC-02, RC-03, RC-21 | S4 P1 Medium |
| HAZ-02 | The PR's head moves (a new push) after Maser loaded the diff. A line comment posted with old line numbers lands on a different line of the new head, or an approval covers commits the user never saw. | H1, H6 | S4 P3 **High** | RC-04, RC-17 (partial) | S4 P1 Medium |
| HAZ-03 | The user comments on a line that's only shown in the full-file view. GitHub silently creates nothing, and the user believes they raised the issue. | H6 | S3 P4 **High** | RC-05 | S3 P1 Low |
| HAZ-04 | A key acts somewhere the user didn't expect. For example, `S`, `c` or Return acts on the open PR while the user is looking at a different, highlighted PR in the queue, or on the wrong pane. Several focus bugs of this kind were found on 2026-11-03 (V8–V10). | H2, H6 | S3 P4 **High** | RC-06, RC-12 | S3 P2 Medium |
| HAZ-05 | The wrong verdict is submitted, such as Approve instead of Comment, or on the wrong PR. | H2, H1 | S4 P2 Medium | RC-07, RC-12 | S4 P1 Medium |
| HAZ-06 | The user discards a pending review by accident, deleting every draft comment. | H3 | S2 P3 Medium | RC-08 | S2 P1 Low |
| HAZ-07 | Maser crashes, or the user quits it, while unsent text is in a comment box or the review summary. The text is only in memory, so it's lost. Four crashes happened on 2026-11-03 (V5). | H3 | S2 P4 Medium | RC-09, RC-14, RC-10 | S2 P1 Low |
| HAZ-08 | The GitHub token leaks through Maser: logged, stored, or sent somewhere. | H4 | S4 P2 Medium | RC-11 | S4 P1 Medium |
| HAZ-09 | Malicious content in a PR's description or comments runs script in Maser, or leads the user to a phishing page. | H4 | S4 P2 Medium | RC-16 | S4 P1 Medium |
| HAZ-10 | `gh` is signed in to a different account than the user expects (personal versus work), so comments and reviews are posted as the wrong identity. | H2 | S3 P3 Medium | RC-12 | S3 P2 Medium |
| HAZ-11 | Maser shows stale status (checks, mergeability, new comments), and the user decides on information that has since changed. | H1 | S3 P3 Medium | RC-17 | S3 P2 Medium |
| HAZ-12 | A `gh` call hangs, and Maser stops responding or never finishes loading. | H5 | S1 P3 Low | RC-15, RC-31 | S1 P1 Low |
| HAZ-13 | Maser runs a `gh` other than the user's own, from a planted binary on the search path or a wrong configured path. | H4 | S4 P1 Medium | RC-13 | S4 P1 Medium |
| HAZ-14 | GitHub returns a capped list (100 items) and Maser shows it as complete, hiding a failing check, a blocking review or a comment. | H1 | S3 P3 Medium | RC-02 | S3 P1 Low |
| HAZ-15 | Development: a live write test posts to a real PR other than the test PR. | H2 | S3 P2 Medium | RC-19 | S3 P1 Low |
| HAZ-16 | A mistake in `config.toml` silently changes or removes bindings, so keys act unexpectedly (leading to HAZ-04). | H2 | S3 P3 Medium | RC-18 | S3 P1 Low |
| HAZ-17 | A line comment is attached to the wrong line or side, because a cursor line is mapped to GitHub's line numbers incorrectly, for example for a range across hunks or sides. | H6 | S3 P3 Medium | RC-01, RC-20 | S3 P1 Low |
| HAZ-18 | The agent misdescribes the change. A diagram leaves out a state or transition, shows a changed part as unchanged, or invents code that isn't there. The user relies on it instead of the diff and approves a defect. | H1 | S4 P3 **High** | RC-29, RC-30, RC-25 | S4 P2 Medium |
| HAZ-19 | A comment the agent added to the pending review is wrong, misleading or misplaced, and the user submits it without reading it. It appears under their name. | H2, H6 | S3 P3 Medium | RC-26, RC-04, RC-12 | S3 P1 Low |
| HAZ-20 | Text in the PR, its comments, or the repository's files steers the agent (prompt injection): to misdescribe the change, add misleading comments, or reveal data, such as files outside the checkout or the user's connected services (mail, documents), which `claude` loads by default. | H1, H2, H7 | S4 P3 **High** | RC-22, RC-26, RC-27, RC-29 | S4 P2 Medium |
| HAZ-21 | Code from an organization that hasn't approved it is sent to the model provider through the agent. | H7 | S3 P3 Medium | RC-24 | S3 P1 Low |
| HAZ-22 | The agent, or Maser preparing its checkout, changes the user's own clone or pushes: local work is lost, or a push appears under their name. | H3, H2 | S3 P2 Medium | RC-23, RC-22 | S3 P1 Low |
| HAZ-23 | Settings, hooks, agents or MCP servers from the PR's repository load into the agent and run code on the user's Mac. A PR can be written to attack its reviewer. | H4 | S4 P3 **High** | RC-22 | S4 P1 Medium |
| HAZ-24 | A diagram from the agent runs script, or loads remote content, in Maser's canvas. | H4, H7 | S4 P2 Medium | RC-28 | S4 P1 Medium |
| HAZ-25 | The agent's answers or diagrams describe an older commit than the one the user is now reviewing. | H1 | S4 P2 Medium | RC-25 | S4 P1 Medium |

## Risk controls

The verification for each control is the verification of its requirements, in [requirements.md](requirements.md).

| ID | Control | Type | Requirements | Status |
| --- | --- | --- | --- | --- |
| RC-01 | The diff parser is verified against the diff shapes GitHub produces: renames, binary files, the no-newline marker, quoted paths. | Inherent safety by design | REQ-DIF-001 | Implemented |
| RC-02 | Every paged list is fetched in full, and truncation is detected rather than shown as complete. | Inherent safety by design | REQ-GH-003, REQ-OVR-001 | Implemented |
| RC-03 | A full file is merged only if its contents match the diff; otherwise Maser shows an error. | Protective measure | REQ-DIF-002 | Implemented |
| RC-04 | Comments and reviews are posted only for the head commit of the diff the user saw: reviews are pinned to it, and the head is checked just before each new line comment and submit, refusing with a refresh when it has moved. | Protective measure | REQ-CMT-007 | Implemented |
| RC-05 | Expanded lines can't take comments, and say why. A comment GitHub doesn't create is shown as an error. | Protective measure | REQ-DIF-003, REQ-CMT-005 | Implemented |
| RC-06 | Key ownership is explicit. The window tracks whether the queue or the review has the keys, the open PR is marked, vim keys pause while typing, and `/` acts only in the queue. | Protective measure | REQ-WIN-002, REQ-WIN-003, REQ-KEY-002, REQ-KEY-003 | Implemented |
| RC-07 | The verdict starts at Comment every time and must be chosen explicitly. Submitting takes a button or ⌘↩ in the sheet. | Protective measure | REQ-CMT-003 | Implemented |
| RC-08 | Discarding a review asks for confirmation, naming the number of drafts it deletes. | Protective measure | REQ-CMT-004 | Implemented |
| RC-09 | The UI avoids the layouts that loop AppKit's constraint updates (nested split views, an inspector beside the file tree), and a stress scenario checks for it. | Inherent safety by design | REQ-WIN-007 | Implemented; UI:tab-and-pane-stress |
| RC-10 | Unsent text is saved locally as it's typed, one file per PR, and restored when the PR is opened again. Each part is cleared once it's posted or discarded. | Protective measure | REQ-CMT-008 | Implemented |
| RC-11 | GitHub access only through `gh`. Maser never handles the token. | Inherent safety by design | REQ-GH-001 | Implemented |
| RC-12 | The account is named wherever Maser posts, and the PR in Finish Review. A post is refused if `gh`'s account changed since it was shown. | Information for safety; protective measure (the refusal) | REQ-CMT-009 | Implemented |
| RC-13 | `gh` is found by a fixed, documented search order, or by an explicit configured path. | Protective measure | REQ-GH-002 | Implemented |
| RC-14 | Defensive decoding; failures become messages, per section in the queue. | Protective measure | REQ-GH-004, REQ-QUE-004 | Implemented |
| RC-15 | Subprocesses never block the UI. | Protective measure | REQ-GH-005 | Implemented |
| RC-16 | Rendered PR content runs no JavaScript, and links open in the default browser. | Inherent safety by design | REQ-OVR-002 | Implemented |
| RC-17 | Data freshness: relative times are refreshed, a PR reloads on return when over 60 s old, and there's a manual refresh (`r`). | Protective measure | REQ-OVR-003, REQ-WIN-001 | Implemented |
| RC-18 | Config problems are reported in a banner and skipped, never silently applied. Shadowed bindings are reported. | Information for safety | REQ-CFG-002 | Implemented |
| RC-19 | Live write tests are hard-coded to bmannakee/maser#1, which `AGENTS.md` requires. | Process control | — (I: `LiveReviewWriteTests`) | Implemented |
| RC-20 | Comment targets are computed from the parsed line numbers on each side, and clipped to one hunk. | Inherent safety by design | REQ-CMT-001 | Implemented |
| RC-21 | Every diff line is drawn in full: long lines wrap inside their row, and a scenario checks that no line's text leaves its row. Found in use on 2026-11-10, when wrapped lines were drawn partly under the next line. | Inherent safety by design | REQ-DIF-009 | Implemented; UI:long-lines-wrap |
| RC-22 | The agent is confined. It's the user's own `claude`, so Maser holds no credential. Its tool set is fixed by Maser: read-only file tools in its checkout, and Maser's tools. It has no shell, no web, no other MCP servers or connectors, no reads outside its checkout, and no settings, hooks or `CLAUDE.md` from the PR's repository. It can't submit or post publicly. | Inherent safety by design | REQ-AGT-002, REQ-AGT-003, REQ-AGT-008 | Implemented |
| RC-23 | The agent reads a separate checkout that Maser owns. The user's clone is only ever read. | Inherent safety by design | REQ-AGT-004 | Implemented |
| RC-24 | The agent is off unless `config.toml` allows the PR's owner or host, and the pane shows what it can read. | Protective measure | REQ-AGT-005 | Implemented |
| RC-25 | A conversation is pinned to a commit. Answers about an older commit are marked as such, and the checkout follows the head. | Protective measure | REQ-AGT-006 | Implemented |
| RC-26 | Agent comments go through the user's checks (head, account, line in the diff), are badged as the agent's, and Finish Review asks before submitting ones the user hasn't opened. Each one says on GitHub that an agent drafted it. | Protective measure; information for safety | REQ-AGT-007 | Implemented |
| RC-27 | Every agent action is shown in the conversation as it happens. | Information for safety | REQ-AGT-010 | Implemented |
| RC-28 | The canvas renders only declarative diagram source, with bundled renderers, no network, and no agent script or HTML. | Inherent safety by design | REQ-CNV-002 | Implemented |
| RC-29 | Diagrams are grounded: each element's citation is checked against the checkout, and each change mark against the diff. Mismatches and unsourced diagrams are flagged. | Protective measure | REQ-CNV-003, REQ-CNV-004 | Implemented |
| RC-30 | Everything the agent produces is labeled as the agent's, with its commit, and none of it changes review state. | Information for safety | REQ-CNV-005 | Implemented |
| RC-31 | Every `gh` call has a timeout. A call past it is stopped and reported with a way to try again; a timed-out write says it may have reached GitHub. | Protective measure | REQ-GH-007 | Implemented |

## Residual risk

The residual risks that are Medium are acceptable only with a reason, recorded here:

- **HAZ-01, HAZ-05, HAZ-08, HAZ-09, HAZ-13:** these are Medium because the harm is Critical, even at Improbable.
  Further reduction would mean independent verification of the diff against the GitHub web view, or of `gh` itself,
  which isn't practicable for a client of `gh`. GitHub's own branch protection and other reviewers remain controls on
  H1.
- **HAZ-02:** Medium because the harm is Critical, even at Improbable. GitHub places a new line comment on the PR's
  current head whatever commit its review is pinned to (found by L:LiveReviewWriteTests.reviewIsPinnedToCommitSeen), so
  RC-04 checks the head immediately before each post. A push in the second between that check and the post isn't
  caught. A review started at an older commit is submitted for that commit, which covers less than the user saw, not
  more.
- **HAZ-04:** Medium. RC-12 names the PR in Finish Review, and the comment boxes sit inside the PR they post to. The
  key-routing controls (RC-06) are verified by the repeatable scenarios UI:key-routing, UI:queue-keys and
  UI:typing-pauses-keys; mouse clicks are still checked only by hand. HRUS-1 is yet to be evaluated with the user.
- **HAZ-07:** Low. RC-10 writes each keystroke's text to disk before the next, so a crash loses at most the key being
  handled (UI:draft-survives-relaunch kills the app without warning). The control brings risks of its own, judged
  acceptable: unsent review text sits in a file under the user's Library, as readable as the rest of their home folder;
  and a crash in the moment after a post succeeds but before its text is cleared brings the text back, so the user
  could post it twice, which is visible and easily deleted. A restored line comment is checked against the head like
  any other (RC-04), so it can't be posted onto a diff the user hasn't seen.
- **HAZ-10:** Medium. RC-12 shows the account on every post button and in Finish Review, and refuses a post when the
  account changed after it was shown (UI:names-pr-and-account). It still relies on the user reading the account when
  `gh` was on the wrong one from the start, which is information for safety, the weakest kind of control. HRUS-7 is
  yet to be evaluated with the user.
- **HAZ-11:** Medium. A "loaded at" indicator on the Overview would reduce it further. It's recorded as a candidate
  control, not yet a requirement.

- **HAZ-12:** Low. RC-31 stops a `gh` call that runs past `[github] timeout` and says so, with Try Again
  (UI:gh-times-out). A write stopped by the timeout may still have reached GitHub, so its message says to check before
  posting again: a second post would be a visible duplicate, not a hidden one.

Of the risks above, none is waiting on a further control. The review agent's are below.

**The review agent (#32)** was built in increments on 2026-11-12. The conversation came first, with RC-22 to RC-25 and
RC-27:

- **HAZ-21:** Low. The agent stays off until the user names the owner, and the tab names the setting and the
  condition (UI:agent-off-until-allowed). It still relies on the user knowing the owner's policy.
- **HAZ-22:** Low. The checkout is Maser's own, made by fetching from the user's clone, which only reads it
  (T:AgentCheckoutTests).
- **HAZ-23:** Medium because the harm is Critical. The confining flags are pinned by T:AgentTests.commandLine and
  checked against the real `claude` (L:LiveAgentTests.bridge; spike V1 to V5). A future `claude` that changed what these
  flags do would reopen it, which is why the live test runs before changes to how the agent is run.
- **HAZ-25:** Medium because the harm is Critical. A conversation about an older commit is marked, and the next message
  moves the agent on and tells it so (UI:agent-follows-head).

The canvas was built the same day, with RC-28 to RC-30:

- **HAZ-24:** Medium because the harm is Critical. Unsafe source is refused before rendering, Pele runs outside any
  page with links and images off, and the canvas shows the SVG with page JavaScript off, no network, and every
  navigation refused (UI:canvas-rejects-script, T:DiagramTests.sourceProblems).
- **HAZ-18:** controls built; for the estimate, see below.

The agent's comments were built the same day, with RC-26:

- **HAZ-19:** Low. An agent comment goes in through the user's own posting path (head, account, a line in the diff),
  says on GitHub that an agent drafted it and with which model, is badged in the comments pane, and Finish Review
  asks before submitting any the user hasn't opened (UI:agent-comments-marked).
- **HAZ-20:** controls built; for the estimate, see below.

Three hazards started High:

- **HAZ-18** (the agent misdescribes the change): Medium, at P2. The defining risk of the feature, since a convincing
  diagram invites the user to stop reading the diff. RC-29 checks what can be checked mechanically, citations and
  change marks, but not whether a diagram is complete. The evaluation of 2026-11-12 (V-2026-11-12/V13) found 6 of 6
  diagrams right on the first drawing, after fixing two things it found in Maser's instructions to the agent. Its cases
  are small, so it supports P2 (Remote), not P1. HRUS-9, whether the user notices a wrong diagram, is still to be
  evaluated with the user.
- **HAZ-20** and **HAZ-23** (a PR written to attack its reviewer): Medium. The evaluation's injected instruction was
  resisted in 3 of 3 runs, and reported to the user each time (V-2026-11-12/V13), as in the spike (V-2026-11-12/V7).
  RC-22 removes the agent's means to act on the Mac or the network, and settings from the PR are never loaded. What's left is the agent's words, which RC-26, RC-27 and
  RC-29 put in front of the user rather than acting on them.

The agent's comments carry the user's name on GitHub, so each one also says that an agent drafted it, naming the
model (decided 2026-11-12). Colleagues reading the review can weigh it accordingly, even if the user submitted it
unread. Conversations are kept in `claude`'s own session store under the user's home folder. That is accepted for this
iteration (H7), and will be revisited if Maser gains other users.

**Overall residual risk:** no residual risk is High. Since RC-04 (2026-11-10) none is for the review features, and
since the review agent was built and evaluated (2026-11-12) none is for the agent. Before Maser, or its agent, is relied
on to review regulated software, the usability evaluation (HRUS-1 to HRUS-12) needs to be run with the user. It is
acceptable for other use.

## Production and post-production

Any problem found in use is a GitHub issue. If it reveals a new hazard, or a control that doesn't work, this file is
updated in the PR that fixes it. The 2026-11-03 crashes and focus bugs are recorded this way: as evidence for HAZ-04
and HAZ-07, and through RC-06 and RC-09.
