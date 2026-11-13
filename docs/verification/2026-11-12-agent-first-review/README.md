# Verification record: the review agent's first real review, 2026-11-12

The first use of the review agent on a real PR: the user reviewed #43 (timeouts on `gh` calls, #21) in Maser with the
agent and its canvas. Before the review, the user asked for a defect to be planted in #43 without being told where, to
see whether the agent would catch it. This is one review, not a repeatable test, so it informs the risk file but
doesn't set a probability.

- **Software:** Maser bundled from the `gh-timeouts` branch at c43ad14 (main at 1b901c9 plus #43), signed ad hoc.
  Claude Code 2.1.323, model claude-opus-5-5 (named in the comments' attribution line), default effort. Pele 1.12.0.
- **Config:** `[agent] allow = ["bmannakee"]`, `repositories = ["~/dev"]`; nothing else set.
- **Performed by:** the user (the review in Maser). The conversation was read back from Maser's saved transcript, and
  the comments from GitHub, by Claude Code (agent), which also wrote this record and the fixes.
- **Cost:** $0.45 over two turns ($0.38 and $0.07).
- **The planted defect:** `GitHubCLI.isWrite(_:)` recognized a GraphQL mutation only when its document began
  `mutation {`. Every mutation Maser sends takes variables (`mutation($review: ID!) {`), so none matched, and a
  timed-out line comment, reply, review start, submit or delete would have told the user to try again instead of
  warning that GitHub may already have it. That invites a duplicate post or a second submit. The one unit test used
  `mutation { deleteThing }`, so it passed.

## Summary

| # | Check | Result | Led to |
| --- | --- | --- | --- |
| V14 | A diagram on request, and the grounding check on it | Correct state machine of a `gh` call; the first drawing's 3 flags were all real mistakes, and the redraw had none | Nothing; REQ-CNV-004 works on a real PR |
| V15 | What the agent found without being asked to review | 3 real defects in #43's timeout code, each stated with what it hadn't checked | All 3 fixed in #43, each with a test that fails on the old code |
| V16 | Whether it caught the planted defect | Missed. It named `isWrite` as what picks the warning, citing its lines, but didn't look at its logic | Fixed in #43, tested through Maser's real mutations; a note on HAZ-18 |
| V17 | Its comments through the user's pending review, on a real PR | 3 comments added, 1 placement refused and corrected; attribution line on each; Finish Review asked before submitting them unopened | Evidence for REQ-AGT-007; issue #44 found along the way |

## Details

### V14: A diagram on request

The user's only request in the first turn was "show me the life of a gh call as a state machine". The agent called
`pr_context`, read `GitHubCLI.swift` lines 340–449 in the checkout, and drew a 15-transition state machine:
ComputeTimeout → FindExecutable → Running → (TimerFired) → Draining → Classify → TimedOut, Failed or Succeeded, with
LaunchFailed off FindExecutable. 25 elements, each citing lines in `GitHubCLI.swift`.

The first drawing had 3 flags from the grounding check, and each was a real mistake in its change marks:

- `FindExecutable` and `edge1` cited line 355, which the PR changed (the call to `Subprocess.run` gained `timeout:`),
  but were marked unchanged.
- `edge5` (`Running → TimerFired`) was marked added, citing line 432, the timer's `Task.sleep`, which predates the PR.

The agent redrew with the marks corrected (and edge labels added); the second drawing had no flags. Compared with the
code by Claude Code: the states, transitions and conditions match `GitHubCLI.run` and `Subprocess.run` at c43ad14,
including the timeout condition (`stopped` and `uncaughtSignal`) and `isWrite` choosing the message.

### V15: Findings it wasn't asked for

The request was for a diagram, not a review. In its answer, under "Three gaps the diagram shows. I haven't tested any
of them", the agent listed:

1. **No SIGKILL.** The timer sends SIGTERM only; a `gh` that ignores it still hangs the call.
2. **Held pipes.** The wait ends only when both pipes close and the process exits, so a child that inherited the
   pipes keeps the call waiting after `gh` is killed.
3. **The timeout check needs a signal death.** A `gh` that catches SIGTERM and exits with its own status is reported
   as an ordinary failure, losing the timeout message and, for a write, the warning. It said it didn't know whether
   `gh` catches SIGTERM, and that the tests only use processes that die from the signal.

It added no comments until the user asked ("please add all three gaps as review comments"). All three are real. Each
is now fixed in #43, with a test that fails on the old code and passes on the fix (checked by reverting each fix):
`GitHubTimeoutTests.killsAProcessIgnoringTerm` (checks the process is gone, not just that the wait ended),
`.childHoldingPipes` (the child leaves the process group, since Foundation's `Process` stops the group: a plain
background child didn't survive to hold the pipes) and `.catchingTermStillTimesOut`.

The second finding had also occurred to Claude Code while writing #43, which left it out; the other two hadn't.

### V16: The planted defect

Missed. The agent's answer said "`isWrite` decides which warning the message shows (`:119-126`)", so it had found the
function and cited it, but it said nothing about how `isWrite` decides, and its third finding worried about writes
losing their warning without checking that writes were recognized at all. It was asked for a diagram, not a review, so
this is not a measure of how it reviews when asked to.

Fixed in #43: `isWrite` now reads the GraphQL document's first word, and
`GitHubTimeoutTests.realCallsTimeOut` sends Maser's own `addComment`, `deleteReviewComment` and `discardReview` through
a `gh` that never answers, expecting the write warning (and the read message for `fileDiffs`). It fails on the planted
version.

What this shows: an agent that finds three real defects unprompted can still miss a fourth beside them, and its
findings give no sign of what it didn't look at. A user who reads its findings as a review of the PR would have
approved the planted defect (HAZ-18).

### V17: Comments on a real PR

The agent's second turn added three comments to the user's pending review on #43, all in `GitHubCLI.swift`:

- Lines 433–434 (SIGKILL) and line 443 (the timeout check) were added as asked.
- Lines 437–440 (held pipes) were refused: "Line 437 of Sources/MaserCore/GitHubCLI.swift isn't in the diff." The agent
  put the comment on line 440, the nearest line it could, named lines 437–439 in the comment, and told the user so.

Each comment ended with "_Drafted by an agent (claude-opus-5-5) in Maser._". When the user pressed `S` (Finish
Review), Maser asked about the 3 agent comments they hadn't opened; the user cancelled, then later submitted the review
("please see agent comments"). The comments appear on GitHub under the user's account with the attribution line.

Along the way, after cancelling that question, the file tree drew `GitHubCLI.swift` (the file with the agent's
comments, not the selected one) with its name overprinted, until the review was submitted: issue #44.

## Not checked

- Whether the agent finds the planted defect when asked to review the PR, rather than to draw it. One trial either way
  wouldn't set a rate.
- Whether a real `gh` catches SIGTERM or leaves children holding its pipes; the fixes cover both without knowing.
