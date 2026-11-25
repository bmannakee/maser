# Verification record: the first release, v0.1.0, 2026-11-23

What was checked on the first signed, notarized release and its installer (REQ-PLT-006, REQ-PLT-007, HAZ-29). It follows
[the stand-in checks of 2026-11-22](../2026-11-22-signed-release/README.md), which couldn't have a real release.

- **Software:** release v0.1.0 at `a73d538` (main after PR #72), built by `scripts/release 0.1.0`.
- **Environment:** a Mac with macOS 27.0.1 and Xcode 27.1 (V1–V4); the user's managed work Mac with macOS 26 (V5, added 2026-11-25).
- **How:** the script's own checks, then the draft's files downloaded with `gh` and installed with the real installer,
  then `MASER_UI_HARDENED=1 scripts/check-ui`, then the public install command run over the network.
- **Performed by:** Claude Code (agent), at the user's request, with the user's Developer ID and notarization login; V5 by the user.

## Summary

| # | Check | Result | Led to |
| --- | --- | --- | --- |
| V1 | `scripts/release` | It ran `scripts/check`, built the universal app, signed it as Developer ID Application, hardened runtime, with a secure timestamp, submitted it, and Apple accepted it. It stapled the ticket, found Gatekeeper's verdict `Notarized Developer ID`, found the installer's team ID matching, and created a draft release with `Maser.zip` and `Maser.zip.sha256`. | REQ-PLT-006 |
| V2 | The draft's files, installed with the real installer | `Maser.zip` downloaded from the draft matched its checksum. `scripts/install.sh` accepted it (against a local copy of the release folder, into a scratch folder): `codesign -dv` showed Authority Developer ID Application: BRIAN KENDALL MANNAKEE (5TF9N64U4P), Developer ID Certification Authority, Apple Root CA, flags `runtime`, TeamIdentifier 5TF9N64U4P; `spctl -a -vv` said `accepted`, `source=Notarized Developer ID`; `stapler validate` worked; both `x86_64` and `arm64` were present; the version was 0.1.0. | REQ-PLT-007 |
| V3 | The hardened runtime against maser's behavior | `MASER_UI_HARDENED=1 scripts/check-ui`: all 28 scenarios passed with the test app signed ad hoc with the `runtime` flag (confirmed by `codesign -dv`): diagrams (JavaScriptCore with Pele), the agent's subprocesses, the web views, keys and focus. The test app was closed afterward. | REQ-PLT-006 |
| V4 | The published release, installed over the network | After publishing, `curl -fsSL https://raw.githubusercontent.com/bmannakee/maser/v0.1.0/scripts/install.sh \| MASER_INSTALL_DIR=<scratch> sh` downloaded `…/releases/latest/download/Maser.zip` and installed 0.1.0; `spctl` said `accepted`, `source=Notarized Developer ID`. | REQ-PLT-007 |
| V5 | The published release, installed on the work Mac | Added 2026-11-25, as the user reported it: v0.1.0 was installed on their managed Mac with macOS 26 using the install command from docs/install.md, opened, and ran cleanly. No Gatekeeper or policy prompt was reported. Using it there found #74 (a PR over GitHub's 20,000-line diff limit). Not captured: the installer's output, the exact macOS 26 version, whether the user or their agent ran the command. | REQ-PLT-001, REQ-PLT-006, REQ-PLT-007 |

## Details

### V1: `scripts/release`

Run from `main` at `a73d538`, clean and equal to `origin/main`. The script stops at the first failed check, so the
release existing at all means each passed: `scripts/check`; the universal build; `codesign` with the Developer ID
identity and the hardened runtime; Apple's notary service answering Accepted; `stapler validate`; `spctl` saying
`Notarized Developer ID`; and `maser_team_id` in `scripts/install.sh` naming the signing team. The first keychain
prompt to let `codesign` use the key was answered Always Allow.

### V2: The draft's files

`gh release download v0.1.0` fetched `Maser.zip` and `Maser.zip.sha256` from the draft; `shasum -a 256 -c` said OK.
`scripts/install.sh` ran with `MASER_RELEASE_BASE` pointing at a folder holding them and `MASER_INSTALL_DIR` at a
scratch folder, so the user's `~/Applications` wasn't touched.

### V3: The hardened runtime

`MASER_UI_HARDENED=1 scripts/check-ui` signs the test app with `--options runtime`, as the release is. `codesign -dv`
showed `flags=0x10002(adhoc,runtime)`. Ad hoc signing has no team, so library validation sees the same rules but not
the same signer: this shows that nothing maser does needs a hardened-runtime exception, not that the Developer ID build
passes the same scenarios.

### V4: The published release over the network

After `gh release edit v0.1.0 --draft=false`, the command in docs/install.md was run with `MASER_INSTALL_DIR` set to a
scratch folder. It downloaded `https://github.com/bmannakee/maser/releases/latest/download/Maser.zip` and its checksum,
passed every check, and installed 0.1.0. `https://github.com/bmannakee/maser/releases/latest/download/Maser.zip`
answered 200.

## Not checked

- macOS 26 beyond V5: it ran there, but the installer's output and the exact version weren't recorded.
- The real notarized build under `scripts/check-ui`: V3 used the test app's ad hoc signature with the same hardened
  runtime, not the Developer ID build.
- A corporate proxy, and a policy that restricts which developers' apps may run: the work Mac installed and ran it (V5), but
  nobody checked which policies it has.
- The installer's refusals against a real release that was altered: those were tested on stand-ins (V-2026-11-22/V1).

### V5: the work Mac

Reported by the user in conversation on 2026-11-25: "It opened and ran cleanly." This record has no capture of it, so it
rests on their word.
