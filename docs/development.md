# Building and maintaining Hearth

## Local builds

Requires Xcode 26+ with Swift 6.2 or later and an accepted Xcode license.
SwiftNIO is the only direct package dependency; `Package.resolved` pins its
dependencies. There is no Node runtime or frontend build step.

```sh
swift build -c release
scripts/package-app.sh
scripts/package-installer.sh
```

Building does not install or register a system service. The portable
`dist/Hearth.app` can read actual settings, but power changes require an enrolled,
compatible helper. Package scripts refuse existing outputs; use `--output` for
another app location or `--output-dir` for another package directory.
`--release-bin /absolute/path` packages existing release binaries without SwiftPM.

On machines with Git's `safe.bareRepository=explicit`, SwiftPM's bare dependency
caches need this command-local setting, which the package scripts already use:

```sh
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all swift build -c release
```

## Signing and installation

Local packages are unsigned and are not Developer ID/notarized distributions.
They do not authenticate a publisher. Release binaries use ad-hoc signatures
with hardened runtime, and a protected manifest enrolls their exact CodeDirectory
hashes. Rebuilds require explicit setup/update; they do not silently replace the
approved code or bypass macOS maintenance consent.

The selected local mechanism is a root-installed launchd helper, not a claim that
ad-hoc builds satisfy SMAppService daemon notarization. See
[the design](design.md) and [packaging contracts](../Packaging/README.md).
Do not disable Gatekeeper, strip quarantine, or weaken system policy to install.

| Item | Installed location |
|---|---|
| App and bundled CLI | `/Applications/Hearth.app` |
| CLI shortcut | `/usr/local/bin/hearth` |
| Privileged executable | `/Library/PrivilegedHelperTools/dev.girishkvs.hearth.helper` |
| launchd definition | `/Library/LaunchDaemons/dev.girishkvs.hearth.helper.plist` |
| Protected identity policy | `/Library/Application Support/Hearth/authorization.plist` |
| Per-user restore state | `~/Library/Application Support/Hearth/state.json` |

The bundle retains the project MIT license and separate dependency licenses,
notices, and SwiftNIO's privacy resource. Shell startup files and app login items
are not modified. `hearth setup` prints instructions without opening Installer.

## Maintenance

Use the setup package for an explicitly approved install/update and the companion
removal package for removal. Neither normal power controls nor missing-helper
errors launch maintenance automatically.

```sh
scripts/uninstall.sh --help
# After restoring successfully in the ready app, if desired:
scripts/uninstall.sh --restored --gui
# Or deliberately retain settings:
scripts/uninstall.sh --keep-settings --cli
```

The wrapper never invokes a potentially older CLI. Incomplete or unverified
maintenance is refused; there is no force-delete repair mode. User state and the
permanent root operation lock are retained.

`scripts/install.sh --gui` opens the current-version setup package in Installer;
`--cli` executes fixed `/usr/sbin/installer` through explicit sudo. Both use the
same reviewed package/backend, preserve real exit status and never run as a
fallback from normal controls. `--package` selects a validated local artifact;
defaults cannot pick the old unversioned private-development package.

Successful scripts-only installations can appear in Apple's installation history
without an Apple receipt plist/BOM or `pkgutil` registration. Maintenance therefore
requires Hearth's own protected manifest, full matching inventory, policy, and
code signatures; Apple receipts are validated when present. Orphaned or foreign
receipts still cause refusal. No receipt is fabricated, and absent receipts are
never passed to `pkgutil --forget`.

Earlier local packages incorrectly required an Apple receipt. For future
maintenance, use a package built from the corrected source after review and
explicit approval. A source update does not replace installed binaries or
reconfigure the running helper.

An explicitly approved repair of a specific unchanged, empty support directory
can be prepared with `scripts/capture-support-repair.sh /absolute/local/approval.plist`
and `package-installer.sh --repair-empty-support /absolute/local/approval.plist`.
Capture is read-only. Fingerprints stay in local artifacts, not committed source.
The opt-in package carries its own repair disclosure; normal setup does not.

## Targeted validation and resource previews

```sh
swift test
.build/release/HearthApp --smoke-test
scripts/test-install.sh
scripts/test-package.sh --fixture
scripts/test-package.sh /absolute/package-directory
scripts/tests/installer-progress-tests.sh
```

For the complete first-party release procedure, version contract and checksum
artifacts, see [releasing](releasing.md). Refresh committed documentation images
with `scripts/capture-docs.sh`; it copies only the intended sample images.
Progress replays use stock macOS Bash, AWK and isolated pseudo-TTY fixtures. They
exercise the formatter/authentication boundary without invoking sudo or Installer,
and generate a clearly labeled replay image rather than live-install evidence.

Use the smallest relevant selector for source changes. Installer copy/layout
changes need only the existing resource tests:

```sh
HEARTH_INSTALLER_PREVIEW_DIR=/absolute/session-artifacts/installer-previews \
  swift test --filter InstallerPageTests
```

These tests render the actual resources through WebKit at Installer-sized
content bounds in light and dark appearances. Optional PNGs are resource previews,
not screenshots of Apple's Installer application; they need no screen-recording
permission and do not open Installer or alter the installed app/helper.

The web page has a separate fake-backend preview mode in its existing tests:

```sh
HEARTH_WEB_PREVIEW_DIR=/absolute/session-artifacts/web-previews \
  swift test --filter HearthPageTests
```

These previews do not use the installed helper or the user's live server. The
primary action follows actual settings and Hearth ownership; Advanced contains
targets, explicit timeouts, refresh/timestamps, and details. The native menu uses
the same primary-action/Advanced structure. Action errors are not cleared by a
later successful status refresh.

The package title remains `Hearth`: Apple's Installer adds the native `Install`
prefix and welcome heading. Its Dock and macOS menu-bar application name remains
`Installer`; changing that host identity would require a separate application.

Real installation, system-domain activation, reboot persistence, and power
changes require separate approval. Fake tests do not establish those outcomes.

## Interface details

Status JSON includes `schemaVersion`, `currentSource`, `profiles`, `warnings`,
and `helper` (`state` and `message`). Unavailable values are omitted. Failed and
partial operations return nonzero CLI exit status with per-profile results.
Explicit timeouts accept 1 through 2147483647 minutes.

The web server binds only to `127.0.0.1`. `hearth web --port N` selects a port.
Its per-run fragment token moves to an Authorization header for APIs; exact
Host/Origin checks and bounded requests remain enforced. Routes are `GET /`,
authenticated `GET /api/status`, and authenticated `POST /api/power`.
Power JSON uses `action`, `target`, and `minutes` only for `sleep`.
