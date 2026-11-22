#!/bin/sh
# Installs maser from its latest GitHub release: curl -fsSL <url of this file> | sh
#
# Downloads Maser.zip and its checksum from the release, then refuses to install unless the checksum matches, the
# app's code signature is intact, it was signed by maser's Developer ID team, and Gatekeeper accepts it as notarized.
# The app goes in ~/Applications (no sudo, no admin rights). Nothing is opened, changed outside that folder, or
# stripped of its quarantine flag. docs/install.md has the instructions this serves.
#
# Environment:
#   MASER_VERSION       Install this release (such as 0.1.0) instead of the latest.
#   MASER_INSTALL_DIR   Install here instead of ~/Applications.
#   MASER_TEAM_ID       The Developer ID team the app must be signed by. Default: maser's own, below. Set this to
#                       install a fork's release.
#   MASER_RELEASE_BASE  Where releases are downloaded from. Default: https://github.com/bmannakee/maser/releases.
#                       It exists so the installer can be tested against a local folder (Tests/Install).
#
# The whole script is one function called on the last line, so a download cut short runs nothing.

# The Apple Developer ID team that signs maser's releases. Printed by `codesign -dv Maser.app` as TeamIdentifier.
maser_team_id="__TEAM_ID__"

main() {
    set -eu

    team_id="${MASER_TEAM_ID:-$maser_team_id}"
    base="${MASER_RELEASE_BASE:-https://github.com/bmannakee/maser/releases}"
    install_dir="${MASER_INSTALL_DIR:-$HOME/Applications}"

    fail() {
        echo "maser install: $*" >&2
        exit 1
    }

    [ "$team_id" != "__TEAM_ID__" ] || fail "this copy of the installer has no Developer ID team set, so it can't check who signed the app."
    [ "$(uname -s)" = "Darwin" ] || fail "maser runs on macOS only."
    [ "$(id -u)" -ne 0 ] || fail "don't run this as root or with sudo; it installs into your own folder."
    major="$(sw_vers -productVersion | cut -d. -f1)"
    [ "$major" -ge 26 ] || fail "maser needs macOS 26 or later; this Mac has $(sw_vers -productVersion)."
    for tool in curl shasum ditto codesign spctl plutil; do
        command -v "$tool" >/dev/null 2>&1 || fail "$tool isn't available."
    done

    if [ -n "${MASER_VERSION:-}" ]; then
        url="$base/download/v$MASER_VERSION"
    else
        url="$base/latest/download"
    fi
    # Only https, including after redirects, unless a test points the installer at a local folder.
    proto="--proto =https --proto-redir =https --tlsv1.2"
    [ -z "${MASER_RELEASE_BASE:-}" ] || proto=""

    work="$(mktemp -d "${TMPDIR:-/tmp}/maser-install.XXXXXX")"
    trap 'rm -rf "$work"' EXIT

    echo "==> Downloading $url/Maser.zip"
    # shellcheck disable=SC2086 # $proto is several flags, or nothing
    curl -fsSL $proto -o "$work/Maser.zip" "$url/Maser.zip" || fail "couldn't download Maser.zip. Is there a release$([ -z "${MASER_VERSION:-}" ] || echo " v$MASER_VERSION")?"
    # shellcheck disable=SC2086
    curl -fsSL $proto -o "$work/Maser.zip.sha256" "$url/Maser.zip.sha256" || fail "couldn't download the checksum."

    echo "==> Checking the checksum"
    (cd "$work" && shasum -a 256 -c Maser.zip.sha256 >/dev/null 2>&1) || fail "the download doesn't match its checksum; nothing was installed."

    echo "==> Unpacking"
    mkdir "$work/unpacked"
    ditto -x -k "$work/Maser.zip" "$work/unpacked"
    app="$work/unpacked/Maser.app"
    [ -d "$app" ] || fail "the download doesn't contain Maser.app."

    echo "==> Checking the signature"
    codesign --verify --deep --strict "$app" 2>/dev/null || fail "the app's signature is broken; nothing was installed."
    signed_by="$(codesign -dv --verbose=2 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [ "$signed_by" = "$team_id" ] || fail "the app is signed by team '$signed_by', not '$team_id'; nothing was installed."
    # Notarized, not just signed: this is the check macOS runs before it opens an app from the internet.
    verdict="$(spctl --assess --type execute --verbose=2 "$app" 2>&1)" || fail "macOS won't open this app: $verdict"
    case "$verdict" in
    *"Notarized Developer ID"*) ;;
    *) fail "the app isn't notarized ($verdict); nothing was installed." ;;
    esac

    version="$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")"
    dest="$install_dir/Maser.app"
    if [ -d "$dest" ]; then
        old="$(plutil -extract CFBundleShortVersionString raw "$dest/Contents/Info.plist" 2>/dev/null || echo "unknown")"
        if pgrep -f "$dest/Contents/MacOS/Maser" >/dev/null 2>&1; then
            fail "maser is running from $dest. Quit it and run this again; nothing was changed."
        fi
        echo "==> Replacing maser $old with $version"
    else
        echo "==> Installing maser $version"
    fi

    mkdir -p "$install_dir"
    # Copy beside the old one, then swap, so a failure leaves the old maser in place.
    rm -rf "$dest.new" "$dest.old"
    ditto "$app" "$dest.new"
    [ ! -d "$dest" ] || mv "$dest" "$dest.old"
    mv "$dest.new" "$dest"
    rm -rf "$dest.old"

    echo
    echo "Installed maser $version at $dest"
    if ! command -v gh >/dev/null 2>&1; then
        echo "maser needs the GitHub CLI: install gh, then run: gh auth login"
    fi
    echo "Open it with: open \"$dest\""
}

main "$@"
