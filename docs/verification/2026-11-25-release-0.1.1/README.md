# Verification record: release v0.1.1, 2026-11-25

What was checked on the second signed, notarized release, which adds the large-PR diff (REQ-DIF-012) and Show Full File
from the clone (REQ-DIF-013). It repeats the checks of [v0.1.0](../2026-11-23-first-release/README.md) for REQ-PLT-006
and REQ-PLT-007, and leaves out one of them (see Not checked).

- **Software:** release v0.1.1 at `7535cfa` (main after PR #77), built by `scripts/release 0.1.1`.
- **Environment:** a Mac with macOS 27.0.1 and Xcode 27.1. Not macOS 26.
- **How:** the script's own checks, then the draft's files installed with the real installer, then the public install
  command run over the network.
- **Performed by:** Claude Code (agent), at the user's request, with the user's Developer ID and notarization login.

## Summary

| # | Check | Result | Led to |
| --- | --- | --- | --- |
| V1 | `scripts/release 0.1.1` | It ran `scripts/check`, built the universal app (`x86_64 arm64`, version 0.1.1), signed it as Developer ID Application with the hardened runtime, and submitted it. Apple accepted it (submission `8516bd9b-3918-462e-b7d5-4b19dfce50d5`). It stapled the ticket, found Gatekeeper's verdict `Notarized Developer ID` and the installer's team ID matching, and created a draft release. The keychain asked nothing, as the Always Allow from v0.1.0 should give. | REQ-PLT-006 |
| V2 | The draft's files, installed with the real installer | `Maser.zip` and `Maser.zip.sha256` downloaded with `gh` from the draft. `scripts/install.sh` accepted them (from a local copy of the release folder, into a scratch folder). `spctl -a -vv` said `accepted`, `source=Notarized Developer ID`, `origin=Developer ID Application: BRIAN KENDALL MANNAKEE (5TF9N64U4P)`; `codesign -dv` showed flags `runtime` and TeamIdentifier 5TF9N64U4P. | REQ-PLT-007 |
| V3 | The published release, installed over the network | After publishing, `curl -fsSL https://raw.githubusercontent.com/bmannakee/maser/v0.1.1/scripts/install.sh \| MASER_INSTALL_DIR=<scratch> sh` installed 0.1.1; `spctl` said `accepted`, `source=Notarized Developer ID`. `…/releases/latest/download/Maser.zip` answered 200, and the release is not a draft. | REQ-PLT-007 |

## Not checked

- **The hardened runtime against maser's behavior.** v0.1.0's V3 ran every UI scenario with the `runtime` flag. That run
  was not repeated for 0.1.1. The UI scenarios were run, without the flag, on the changes in it (29 passed: [the large-PR
  record](../2026-11-25-large-pr-diff/README.md) and [the full-file record](../2026-11-25-full-file-from-clone/README.md)).
  The new code runs `git` as a subprocess, which v0.1.0's agent checkout already did under the flag, but no run shows the
  new calls under it.
- **The new features in this build.** The release was installed into a scratch folder and not opened. The large-PR path
  has not run on a real PR over 20,000 lines (the large-PR record's Not checked list still holds).
- **macOS 26 with this build**, and an upgrade over a running 0.1.0 on the work Mac (the installer's replace-in-place and
  its refusal while maser runs were tested on stand-ins in V-2026-11-22).
- The refusals against an altered real release, as in v0.1.0.

## Details

### V1: `scripts/release`

Run from `main` at `7535cfa`, clean and equal to `origin/main`, with no tag `v0.1.1` before. The script stops at the first
failed check, so the draft existing means each passed, as for v0.1.0. The release's checksum file begins `08040a58…`.

### V2: the draft's files

The installer's own checks (checksum, signature, team, notarized verdict) all passed before it installed, and `spctl` and
`codesign` were run on the result, as in v0.1.0's V2.

### V3: the published release

Run as in v0.1.0's V4: the same installer checks passed against the files GitHub serves, and `spctl` was run on the result.
