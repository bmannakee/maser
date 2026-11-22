# Verification record: signed release and installer, 2026-11-22

The release script, the installer and the universal build (REQ-PLT-006, REQ-PLT-007, HAZ-29). No release has been
made: the user's Developer ID certificate and notarization login aren't set up yet, so everything that needs Apple is
listed as not checked.

- **Software:** the branch `signed-release`, on a Mac with macOS 27.0.1 and Xcode 27.1.
- **How:** `Tests/Install/run.sh` against stand-in releases signed with the Mac's Apple Development certificate, then
  the same run with each check in the installer disabled in turn; `MASER_UNIVERSAL=1 scripts/bundle`.
- **Performed by:** Claude Code (agent), at the user's request.

## Summary

| # | Check | Result | Led to |
| --- | --- | --- | --- |
| V1 | The installer's refusals and its accepting path | 14 cases passed: it refuses an unsigned app, an ad hoc signed one, one from another team, one altered after signing, one Gatekeeper rejects, one Gatekeeper accepts but not as notarized, a wrong checksum, a missing release, an installer with no team set, and a running maser. It installs a correctly signed release when run through a pipe, upgrades in place leaving nothing beside the app, honors `MASER_VERSION`, and removes its temporary folder. | REQ-PLT-007 |
| V2 | The cases can fail | With the team check, the notarization check, the checksum check or the signature check removed from the installer, the cases for that check failed (and, for the first run, two cases whose messages matched a progress line rather than the refusal, which were tightened). With the running-maser check or the old-app cleanup removed, those cases failed. | REQ-PLT-007 |
| V3 | The universal build | `MASER_UNIVERSAL=1 MASER_VERSION=0.0.0-test scripts/bundle` built in 30 s. `Maser` and `maser-agent-tools` each hold `x86_64` and `arm64`, with a minimum of macOS 26.0, and `CFBundleShortVersionString` was `0.0.0-test`. | REQ-PLT-006 |

## Details

### V1: The installer's cases

Run with `Tests/Install/run.sh`. Each case makes a stand-in `Maser.app` (a shell script in a bundle), signs it, zips it
like a release and runs the installer with `MASER_RELEASE_BASE` pointing at a temporary folder, so nothing touches the
network or the real `~/Applications`. Gatekeeper's real verdict is used for the case that expects a rejection. The
accepting cases put a stand-in `spctl` first on the `PATH`, because a stand-in can't be notarized. That's a limit of the
check, not of the installer: a real release is assessed by `scripts/release` and by the first install on another Mac.

### V2: Mutations

Each check in a copy of `scripts/install.sh` was replaced by one that always passes, and the run repeated. The first
attempt with the checks replaced by ones that always fail showed that failing for every case is no evidence, so the
mutations used pass-always, and two cases (the unsigned app and the wrong checksum) were changed to match the refusal
message instead of a word that also appears in the installer's progress lines.

### V3: Universal build

x86_64 is built because a managed Mac may be either kind. The build warns that x86_64 is deprecated for a macOS 27
target, though maser's own target is macOS 26.

## Not checked

- A real notarization by Apple, and Gatekeeper's verdict on a real release.
- Whether the hardened runtime breaks anything maser does (JavaScriptCore for diagrams, the review agent's
  subprocesses, WebKit): `MASER_UI_HARDENED=1 scripts/check-ui` is the check, and it takes over the keyboard.
- macOS 26: the build has never run on it (REQ-PLT-001).
- `curl` over the network, and the install through a corporate proxy.
