#!/bin/sh
# Tests scripts/install.sh against stand-in releases in a temporary folder: no network, and nothing outside it.
#
# Usage: Tests/Install/run.sh
#
# Each case builds a tiny stand-in Maser.app, signs it, zips it like a release, and runs the installer against it with
# MASER_RELEASE_BASE pointing at the folder. Every case that should refuse checks that nothing was installed. The cases
# that need a real signature use a code-signing identity from the keychain (an Apple Development one is enough); without
# one they are skipped. Gatekeeper's notarization verdict can't be had for a stand-in, so the accepting case puts a fake
# `spctl` first on the PATH: whether a real release is accepted is checked by scripts/release and by the first install.
set -eu
cd "$(dirname "$0")/../.."
installer="$PWD/scripts/install.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/maser-install-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
skipped=0
ok() { echo "✔ $1"; passed=$((passed + 1)); }
bad() { echo "✘ $1"; failed=$((failed + 1)); }

# The signing identity's hash, and the team it belongs to.
identity="$(security find-identity -v -p codesigning | sed -n '1s/^ *1) \([0-9A-F]*\) .*/\1/p')"
team=""
if [ -n "$identity" ]; then
    probe="$work/probe"
    printf '#!/bin/sh\n' > "$probe" && chmod +x "$probe"
    codesign --force --sign "$identity" --options runtime "$probe" >/dev/null 2>&1 || identity=""
    [ -z "$identity" ] || team="$(codesign -dv --verbose=2 "$probe" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
fi

# Makes a release folder $1 holding a stand-in app of version $2, signed by $3: an identity hash, "adhoc" or "none".
release() {
    dir="$1"; version="$2"; signer="$3"
    rm -rf "$work/src" "$dir"
    mkdir -p "$work/src/Maser.app/Contents/MacOS" "$dir/latest/download"
    printf '#!/bin/sh\nexit 0\n' > "$work/src/Maser.app/Contents/MacOS/Maser"
    chmod +x "$work/src/Maser.app/Contents/MacOS/Maser"
    cat > "$work/src/Maser.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.maser.Maser</string>
<key>CFBundleExecutable</key><string>Maser</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
</dict></plist>
PLIST
    case "$signer" in
    none) ;;
    adhoc) codesign --force --sign - "$work/src/Maser.app" >/dev/null 2>&1 ;;
    *) codesign --force --sign "$signer" --options runtime "$work/src/Maser.app" >/dev/null 2>&1 ;;
    esac
    ditto -c -k --keepParent "$work/src/Maser.app" "$dir/latest/download/Maser.zip"
    (cd "$dir/latest/download" && shasum -a 256 Maser.zip > Maser.zip.sha256)
    mkdir -p "$dir/download/v$version"
    cp "$dir/latest/download/"* "$dir/download/v$version/"
}

# A stand-in spctl that says what Gatekeeper says about a notarized app.
mkdir -p "$work/bin"
printf '#!/bin/sh\necho "$2: accepted"; echo "source=Notarized Developer ID" >&2\n' > "$work/bin/spctl"
chmod +x "$work/bin/spctl"
# One that accepts the app but not as notarized: signed with a Developer ID, with no ticket from Apple.
mkdir -p "$work/bin-unnotarized"
printf '#!/bin/sh\necho "$2: accepted"; echo "source=Developer ID" >&2\n' > "$work/bin-unnotarized/spctl"
chmod +x "$work/bin-unnotarized/spctl"

# Runs the installer. $1 is the release folder, $2 the install folder, $3 the team it should expect; the rest is
# environment. The output goes to $work/out, and the status is returned.
run() {
    rel="$1"; dest="$2"; expect="$3"; shift 3
    env "$@" MASER_RELEASE_BASE="file://$rel" MASER_INSTALL_DIR="$dest" MASER_TEAM_ID="$expect" \
        sh "$installer" > "$work/out" 2>&1
}
installed() { [ -d "$1/Maser.app" ]; }

# --- Cases that need no signature ---
release "$work/r-none" 1.0.0 none
if run "$work/r-none" "$work/d1" "ABCDE12345" PATH="$work/bin:$PATH"; then bad "an unsigned app is refused"
elif ! installed "$work/d1" && grep -q "signature is broken" "$work/out"; then ok "an unsigned app is refused"; else bad "an unsigned app is refused (it was installed, or said something else)"; fi

release "$work/r-adhoc" 1.0.0 adhoc
if run "$work/r-adhoc" "$work/d2" "ABCDE12345" PATH="$work/bin:$PATH"; then bad "an ad hoc signed app is refused"
elif ! installed "$work/d2" && grep -q "not 'ABCDE12345'" "$work/out"; then ok "an ad hoc signed app is refused"; else bad "an ad hoc signed app is refused"; fi

if MASER_RELEASE_BASE="file://$work/r-adhoc" MASER_INSTALL_DIR="$work/d3" sh "$installer" > "$work/out" 2>&1; then bad "an installer with no team set refuses"
elif ! installed "$work/d3" && grep -q "no Developer ID team" "$work/out"; then ok "an installer with no team set refuses"; else bad "an installer with no team set refuses"; fi

release "$work/r-sum" 1.0.0 adhoc
echo "0000000000000000000000000000000000000000000000000000000000000000  Maser.zip" > "$work/r-sum/latest/download/Maser.zip.sha256"
if run "$work/r-sum" "$work/d4" "ABCDE12345"; then bad "a wrong checksum is refused"
elif ! installed "$work/d4" && grep -q "doesn.t match its checksum" "$work/out"; then ok "a wrong checksum is refused"; else bad "a wrong checksum is refused"; fi

if run "$work/missing" "$work/d5" "ABCDE12345"; then bad "a missing release is refused"
elif ! installed "$work/d5" && grep -q "couldn't download" "$work/out"; then ok "a missing release is refused"; else bad "a missing release is refused"; fi

# --- Cases that need a real signature ---
if [ -z "$team" ]; then
    echo "- skipped: no usable code-signing identity in the keychain, so the signed cases didn't run"
    skipped=$((skipped + 1))
else
    release "$work/r-ok" 1.0.0 "$identity"
    if run "$work/r-ok" "$work/d6" "OTHERTEAM1" PATH="$work/bin:$PATH"; then bad "an app from another team is refused"
    elif ! installed "$work/d6" && grep -q "not 'OTHERTEAM1'" "$work/out"; then ok "an app from another team is refused"; else bad "an app from another team is refused"; fi

    # Real Gatekeeper: a signed stand-in isn't notarized, so it says no.
    if run "$work/r-ok" "$work/d7" "$team"; then bad "an app Gatekeeper rejects is refused"
    elif ! installed "$work/d7" && grep -q "macOS won't open\|isn't notarized" "$work/out"; then ok "an app Gatekeeper rejects is refused"; else bad "an app Gatekeeper rejects is refused"; fi

    # Accepted by Gatekeeper's rules but with no notarization ticket.
    if run "$work/r-ok" "$work/d7b" "$team" PATH="$work/bin-unnotarized:$PATH"; then bad "an app that isn't notarized is refused"
    elif ! installed "$work/d7b" && grep -q "isn.t notarized" "$work/out"; then ok "an app that isn't notarized is refused"; else bad "an app that isn't notarized is refused"; fi

    # Altered after signing: the zip and checksum are made from the altered app, as an attacker would.
    release "$work/r-alt" 1.0.0 "$identity"
    echo "# altered" >> "$work/src/Maser.app/Contents/MacOS/Maser"
    ditto -c -k --keepParent "$work/src/Maser.app" "$work/r-alt/latest/download/Maser.zip"
    (cd "$work/r-alt/latest/download" && shasum -a 256 Maser.zip > Maser.zip.sha256)
    if run "$work/r-alt" "$work/d8" "$team" PATH="$work/bin:$PATH"; then bad "an app altered after signing is refused"
    elif ! installed "$work/d8" && grep -q "signature is broken" "$work/out"; then ok "an app altered after signing is refused"; else bad "an app altered after signing is refused"; fi

    # The accepting case, with a fake spctl, through a pipe as `curl | sh` runs it.
    if env PATH="$work/bin:$PATH" MASER_RELEASE_BASE="file://$work/r-ok" MASER_INSTALL_DIR="$work/d9" MASER_TEAM_ID="$team" \
        sh < "$installer" > "$work/out" 2>&1 && installed "$work/d9" && grep -q "Installed maser 1.0.0" "$work/out"; then
        ok "a release signed by the right team installs, run through a pipe"
    else bad "a release signed by the right team installs, run through a pipe"; fi
    [ -z "$(ls "${TMPDIR:-/tmp}" 2>/dev/null | grep '^maser-install\.' || true)" ] && ok "the installer cleans up its temporary folder" \
        || bad "the installer cleans up its temporary folder"

    # Upgrading replaces it; a pinned version is the one installed; nothing is left beside it.
    release "$work/r-new" 1.1.0 "$identity"
    release "$work/r-pin" 1.0.5 "$identity"
    cp -R "$work/r-pin/download/v1.0.5" "$work/r-new/download/"
    if run "$work/r-new" "$work/d9" "$team" PATH="$work/bin:$PATH" \
        && [ "$(plutil -extract CFBundleShortVersionString raw "$work/d9/Maser.app/Contents/Info.plist")" = "1.1.0" ] \
        && grep -q "Replacing maser 1.0.0 with 1.1.0" "$work/out" && [ "$(ls "$work/d9")" = "Maser.app" ]; then
        ok "an upgrade replaces the old app and leaves nothing beside it"
    else bad "an upgrade replaces the old app and leaves nothing beside it"; fi
    if run "$work/r-new" "$work/d10" "$team" PATH="$work/bin:$PATH" MASER_VERSION=1.0.5 \
        && [ "$(plutil -extract CFBundleShortVersionString raw "$work/d10/Maser.app/Contents/Info.plist")" = "1.0.5" ]; then
        ok "MASER_VERSION installs that release"
    else bad "MASER_VERSION installs that release"; fi

    # A running maser is never replaced, and the old one stays.
    cp -R "$work/d9/Maser.app" "$work/d11-app" && mkdir -p "$work/d11" && mv "$work/d11-app" "$work/d11/Maser.app"
    "$work/d11/Maser.app/Contents/MacOS/Maser" >/dev/null 2>&1 || true
    printf '#!/bin/sh\nsleep 30\n' > "$work/d11/Maser.app/Contents/MacOS/Maser"
    chmod +x "$work/d11/Maser.app/Contents/MacOS/Maser"
    "$work/d11/Maser.app/Contents/MacOS/Maser" &
    running=$!
    sleep 0.5
    if run "$work/r-new" "$work/d11" "$team" PATH="$work/bin:$PATH"; then bad "a running maser isn't replaced"
    elif grep -q "is running" "$work/out" && grep -q "sleep" "$work/d11/Maser.app/Contents/MacOS/Maser"; then ok "a running maser isn't replaced"
    else bad "a running maser isn't replaced"; fi
    kill "$running" 2>/dev/null || true
fi

echo "$passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
