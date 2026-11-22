# Installing maser

**No release exists yet (#71): until the first is made, the install below stops with an error.**

Instructions for a person or a coding agent installing maser on a Mac. They need no source code, no Xcode and no admin
rights.

maser is a native macOS app for reviewing GitHub pull requests. Releases are signed with a Developer ID and notarized by
Apple, so macOS opens them without any override. **Never tell the user to bypass Gatekeeper** (right-click Open,
`xattr -d com.apple.quarantine`, System Settings overrides). If macOS or the installer refuses the app, stop and report
the message: a refusal means the download isn't the release.

## What it needs

| Need | Check | If missing |
| --- | --- | --- |
| macOS 26 or later | `sw_vers -productVersion` | maser can't run here. Stop and say so. |
| The GitHub CLI, signed in | `gh auth status` | Install `gh` (`brew install gh`, or from cli.github.com), then `gh auth login`. maser reads GitHub only through `gh` and never sees a token. |
| `claude` (optional) | `claude --version` | Only the review agent needs it, and it's off unless the user turns it on in `config.toml`. Skip it unless asked. |

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/bmannakee/maser/main/scripts/install.sh | sh
```

The script downloads the latest release and installs `~/Applications/Maser.app`. It won't install unless all of this
holds: the checksum matches, the code signature is intact, it was signed by maser's Developer ID team, and macOS accepts
it as notarized. It never uses `sudo`, never opens the app, and never touches anything outside `~/Applications`.

To read the script first, download it, read it, then run it:

```sh
curl -fsSLO https://raw.githubusercontent.com/bmannakee/maser/main/scripts/install.sh
less install.sh
sh install.sh
```

Options, as environment variables in front of `sh`:

- `MASER_VERSION=0.1.0` installs that release instead of the latest.
- `MASER_INSTALL_DIR=/Applications` installs there instead (needs write access to it).

## Check it worked

```sh
codesign --verify --deep --strict ~/Applications/Maser.app && echo signature ok
spctl --assess --type execute --verbose=2 ~/Applications/Maser.app     # should say: source=Notarized Developer ID
plutil -extract CFBundleShortVersionString raw ~/Applications/Maser.app/Contents/Info.plist
open ~/Applications/Maser.app
```

The main window should appear with the review queue. If the queue shows an error about `gh`, run `gh auth status`.

## Update

Run the install command again. It replaces the old app, and refuses (changing nothing) if maser is running, so quit it
first.

## Uninstall

```sh
rm -rf ~/Applications/Maser.app
```

Settings live in `~/.config/maser/config.toml`; delete that folder too to remove them.

## If something fails

| Message | Meaning |
| --- | --- |
| `maser needs macOS 26 or later` | This Mac is too old. |
| `couldn't download` | No network, a proxy that blocks github.com, or there is no release with that version. |
| `doesn't match its checksum` | The download was damaged or altered. Nothing was installed; try again, and report it if it repeats. |
| `signed by team …, not …` or `signature is broken` | The app isn't the one maser's releases are made of. Don't install it; report it. |
| `isn't notarized` or `macOS won't open this app` | Same: don't work around it; report it. |
| `maser is running` | Quit maser and run the install again. |

Report problems at https://github.com/bmannakee/maser/issues with the full message.
