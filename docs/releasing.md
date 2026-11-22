# Releasing maser

How a release is made: signed with a Developer ID, notarized by Apple, and uploaded to GitHub Releases, where
`scripts/install.sh` finds it (docs/install.md). The release is built on your own Mac, so the certificate and the
notarization password never leave it and no secret is stored in the repository or in GitHub.

## One-time setup

You need a paid Apple Developer Program membership.

1. **A Developer ID Application certificate.** In Xcode: Settings → Accounts → select the team → Manage Certificates →
   `+` → Developer ID Application. Check it with `security find-identity -v -p codesigning`; it should list
   `Developer ID Application: Your Name (TEAMID)`. (An Apple Development certificate can't be notarized.)
2. **A notarization login.** Make an app-specific password at account.apple.com → Sign-In and Security → App-Specific
   Passwords. Then store it in your keychain under the name `maser-notary`:

   ```sh
   xcrun notarytool store-credentials maser-notary --apple-id YOUR_APPLE_ID --team-id TEAMID
   ```

   It asks for the app-specific password. Check it with `xcrun notarytool history --keychain-profile maser-notary`.
3. **The team ID in the installer.** `scripts/install.sh` refuses any app not signed by the team named in `maser_team_id`.
   Set it to your `TEAMID` (also the `TeamIdentifier` that `codesign -dv` prints for a signed app), and merge that
   through a PR.

## Making a release

From a clean, up-to-date `main`:

```sh
scripts/release 0.1.0            # a draft release: look at it, then publish from the Releases page
scripts/release 0.1.0 --publish  # or publish at once
```

The script runs `scripts/check`, builds a universal app (Apple silicon and Intel), signs it with the hardened runtime,
submits it to Apple and waits for the verdict (a few minutes), staples the ticket, checks that Gatekeeper accepts it as
notarized, and creates the release `v0.1.0` with `Maser.zip` and `Maser.zip.sha256`. It stops, releasing nothing, at the
first thing that's wrong.

The release is the tag's commit, so everything in it is on `main`. After publishing, try the install command in
docs/install.md on a Mac that has never had maser, and record it in `docs/verification/`.

## Version numbers

`MAJOR.MINOR.PATCH`, shown in the app's bundle as `CFBundleShortVersionString`. Tags are `v` plus the version.

## When something goes wrong

- **Apple rejects the build.** The script prints Apple's log. Common causes: an unsigned nested executable, or a
  missing hardened runtime. Both are set in `scripts/bundle`.
- **A bad release is published.** Delete the release and its tag (`gh release delete v0.1.0 --cleanup-tag`) and make a
  new patch version. People who installed the bad one update by running the install command again.
