# Verification record: UI checks leave the test app open, 2026-11-15

Issue #64: after `scripts/check-ui` finished, Maser UI Test was left open, and the user can't tell it from maser when
taking the keyboard back (HAZ-28).

- **Software:** `scripts/check-ui` on main at 5227a2b, then with the change in this record's PR.
- **How:** an orphaned test app found running after a run was inspected, the script's activation step was reproduced
  on its own, and the new cleanup function and traps were run against stand-in programs at a stand-in
  `.build/MaserUITests.app` path, beside a stand-in for a maser the user is running.
- **Performed by:** Claude Code (agent), at the user's request.

## Summary

| # | Check | Result | Led to |
| --- | --- | --- | --- |
| V1 | The leftover test app, and what started it | A plain launch: started 17:14:49, one second after queue-keys finished (17:14:48) in a full run of 27 scenarios, parent launchd, idle in the event loop. Its environment had `MASER_CHECK_UI_AWAKE` (inherited from the script's shell) but none of `MASER_UI_SCENARIO`, `FAKE_GH_*` or `XDG_CONFIG_HOME`, which `open --env` sets. So it wasn't started by the script's `open`, and with no `XDG_CONFIG_HOME` it read the user's real config and ran the real `gh`. | RC-36, HAZ-28 |
| V2 | The activation step starts a closed app | Reproduced: with the test app closed, `osascript -e 'tell application id "dev.maser.Maser.uitests" to activate'` started it (pid 86211). `if application id … is running then tell … to activate` left it closed. | REQ-PLT-005 |
| V3 | The cleanup function and traps | Run against stand-ins: after SIGTERM, after SIGINT, after a failing command under `set -e`, and after a normal finish, no test app was left, and a stand-in for the user's own maser, at another path, kept running. After `kill -9` of the script two were left, and the next run's first step closed them. | REQ-PLT-005 met for these exits |

## Details

### V1: The leftover

The scenarios take 2 s to be activated by the script (`sleep 2`, then `osascript … activate`). A scenario that finishes
sooner leaves nothing running, and the `activate` then starts the app, as in V2. That instance has no scenario to run
and nothing to end it, and the script only waits for the `open -W` launcher of the scenario it started.

The queue-keys log was last written at 17:14:48 and the stray started at 17:14:49.278, within the 2 s of
queue-keys's own launch. This is the likeliest scenario to be that quick, but any that finishes in under 2 s would
do the same, so it can vary from run to run.

### V2: The activation step

See the summary. `tell application id … to activate` starts an application that isn't running; the `if … is running`
form doesn't.

### V3: The cleanup

The stand-ins are shell scripts, because a copy of a system binary is killed on arm64. They were started from
`$S/.build/MaserUITests.app/Contents/MacOS/Maser`, the function and traps were copied from `scripts/check-ui` by
`awk`, and the script's wait loop (1 s sleeps) was reproduced, because `sh` runs a trap only when the foreground
command ends. The first attempt, with one 30 s `sleep`, showed that: the traps ran only after it.

### Not checked

- A full `scripts/check-ui` run with the change: the screen was locked, and the script stops before launching.
- The 120 s timeout path.
- `kill -9` of the script (shown to leave the app, cleared by the next run).
