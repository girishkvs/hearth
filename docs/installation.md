# Install, update, and remove

Hearth 1.2.0 controls **System**, opt-in **Display**, and coordinated
**Lock** idle prevention. Lock uses the current-user saver idle delay plus disclosed
System/Display dependencies; authentication and manual lock remain unchanged.
Hearth 1.0.0 controls system idle sleep only.

## Requirements

- macOS 13+ deployment target; 1.2.0 installed-product acceptance used Apple
  silicon/ARM64 on macOS 26.6.2, not the full deployment-target matrix.
- For source builds: Xcode 26+ with Swift 6.2 or later and an accepted Xcode license.
  Pinned dependencies require Swift 6.2; Command Line Tools alone may not supply
  the AppKit/WebKit test environment.
- A normal user account for build/operation; administrator approval only for
  explicit installation, update, or removal.

Use the [source repository](https://github.com/girishkvs/hearth) or
[release downloads](https://github.com/girishkvs/hearth/releases). Local packages
are unsigned, contain ad-hoc-signed code, and are **not notarized**. Trust the source/artifact before
authorizing it. Checksums detect corruption; they do not authenticate a publisher.

## Build from source

Use a reviewed 1.2.0 checkout or its source archive. For a published version,
select the tag or archive named on its release page; do not assume the default
branch matches a downloaded package. The commands below build 1.2.0, not the
System-only 1.0.0 release.

From the clean, reviewed checkout, choose a new output directory:

```sh
out="$PWD/dist/hearth-1.2.0-reviewed-local"
scripts/prepare-release.sh --output-dir "$out"
package="$out/hearth-1.2.0-macos-$(uname -m)-local-setup.pkg"
```

This builds normal packages and prepares matching source, release notes, build
information and checksums in a new directory. Nothing is installed or registered.
Existing output directories are refused rather than replaced.
For an extracted source archive without `.git`, use:

```sh
swift build -c release
out="$PWD/dist/hearth-1.2.0-reviewed-local"
scripts/package-installer.sh --output-dir "$out"
package="$out/hearth-1.2.0-macos-$(uname -m)-local-setup.pkg"
```

Set `SOURCE_DATE_EPOCH` if you need a fixed package build identifier. Git checkouts
default to the commit timestamp; source archives without Git default to build time.
See [releasing](releasing.md) for repeatable release inputs and limitations.

## Choose GUI or Terminal setup

Both entrypoints validate and install the **same package**, using Apple's Installer
and the same Hearth maintenance backend. Neither runs a power-setting command.

```sh
# Native wizard:
scripts/install.sh --gui --package "$package"

# Real Terminal installation, not a GUI launcher:
scripts/install.sh --cli --package "$package"
```

The Terminal route invokes only
`sudo -- /usr/sbin/installer -verboseR -pkg <package> -target /`.
Run it directly in one interactive Terminal, without piping to `tee` or redirecting
input/output. Enter credentials only at the normal sudo prompt: password typing
shows no characters, then press Return. The app/web page never collects them.
The default display is one updating ASCII bar with the current native phase and
rounded, reported percentage. Repeated phases do not scroll. Unknown progress stays
unknown; no elapsed-time estimate is invented, and success is shown only after
Installer exits successfully. The native exit status is preserved.

Only Installer's stdout is formatted. sudo still reads from your Terminal and its
authentication prompt/error stream is not captured. Keep the window open until
the final success/failure line. There is no fallback from power controls to setup.

For raw diagnostics, choose `scripts/install.sh --cli --verbose --package "$package"` (also supported
by `uninstall.sh`). This is an explicit installation mode, **not** a reason to
repeat a failed or uncertain update. Check that attempt's Installer log first.

![Compact Hearth Terminal progress showing a replay at 52 percent](images/terminal-progress-dark.png)

*Synthetic native Installer output passed through the production formatter. This
is a replay preview, not another live installation. Refresh it with
`scripts/capture-docs.sh` in an [active GUI session](development.md#targeted-validation-and-resource-previews);
run the safe replay coverage with
`scripts/tests/installer-progress-tests.sh`.*

The default package path is versioned, but it cannot tell which of several local
1.2.0 candidates you intended. Prefer the explicit package selected above. For a
downloaded or relocated package, pass its absolute path:

```sh
scripts/install.sh --gui --package "/absolute/path/hearth-1.2.0-macos-arm64-local-setup.pkg"
scripts/install.sh --cli --package "/absolute/path/hearth-1.2.0-macos-arm64-local-setup.pkg"
```

Use the filename for your actual architecture. Verify `SHA256SUMS.txt` before
opening downloaded artifacts. `--open-installer` remains a GUI alias; no arguments
or `--help` prints guidance without installing.
Setup and removal declare the single architecture verified against their packaged
Mach-O binaries; an Apple silicon build does not require Rosetta for installation.

![Hearth Installer introduction resource in light appearance](images/introduction-light.png)

*Rendered preview of the actual 1.2.0 Introduction resource, not a screenshot of
Apple's Installer or a claim that installation completed. The native wizard adds
its own welcome heading and exact MIT License step.*

![Hearth Installer Read Me resource in dark appearance](images/read-me-dark.png)

*Actual Read Me resource preview. Apple's host remains named Installer in the Dock
and menu bar; the native window is Install Hearth.*

## After setup

In Finder, open **Applications** and double-click **Hearth**. Or run this as your
normal user, without sudo:

```sh
open /Applications/Hearth.app
```

Hearth appears as a **flame icon in the menu bar, not in the Dock**. Click the
flame to see its controls. Setup does not automatically launch the app; you do
not need Spotlight to open it. Terminal/browser controls are also available:

```sh
/usr/local/bin/hearth status
/usr/local/bin/hearth web
```

Confirm **Helper ready** and inspect actual values before changing anything.
Setup does not change sleep settings, shell startup files, or app login items.
The helper is on-demand through launchd. It never changes power merely by starting.

![Hearth Installer first-launch guidance with the exact application path](images/first-launch-light.png)

*Rendered preview of the actual Installer conclusion resource, not a completed
installation screenshot. It directs you to the installed app without relying on
Spotlight.*

| Item | Location |
|---|---|
| App and CLI | `/Applications/Hearth.app` |
| Command link | `/usr/local/bin/hearth` |
| Helper | `/Library/PrivilegedHelperTools/dev.girishkvs.hearth.helper` |
| Service definition | `/Library/LaunchDaemons/dev.girishkvs.hearth.helper.plist` |
| Protected enrollment/inventory | `/Library/Application Support/Hearth/` |
| Your restore state | `~/Library/Application Support/Hearth/state.json` |

## Update

For 1.0.0 to 1.2.0, read [migration](migration.md) first: a valid active System
override is preserved; Display starts unmanaged and requires explicit opt-in.
State/status schema 4, root IPC 2 and user Lock IPC 2 require compatible clients/helper. A rebuilt client alone
does not update the installed helper or earn trust.

Lock uses public current-user preferences with no Automation setup or entitlement.
CLI/web retain the authenticated app-only user service as one serialized writer.
The update does not reset or revoke existing OS permission state. Helper installation
remains separate for System/Display power operations.
The conservative Lock policy gate excludes managed or otherwise unverified accounts.

Restore managed settings first only if you want them restored, otherwise retain
the active override. With approval, close the app and stop
your web server, then explicitly run the **new version's** setup package through
its matching GUI or CLI wrapper. Exact code pinning means a rebuilt client is not
silently trusted. Installed signatures, inventory, ownership and active-operation
locks must validate before replacement. Updates preserve per-user restore state.

Private development builds used `2.0.*` labels. The corrected 1.2.0 build passed
local installed-product acceptance described in the [release notes](releases/1.2.0.md).
The scripts-only updater uses verified Hearth metadata, not an assumed Apple
receipt or version-based overwrite shortcut. Busy, foreign or modified state is
refused, not force-repaired.

## Remove

Removal does not restore or change power or screen-saver settings. If desired,
use native **Restore and quit**, or Restore Lock followed by the remaining
independent System/Display Restore actions, and wait for success.
Select the companion removal package from the reviewed output directory above.
For a downloaded artifact, set `removePackage` to its absolute path instead.
Then choose one removal route:

```sh
removePackage="$out/hearth-1.2.0-macos-$(uname -m)-local-remove.pkg"
scripts/uninstall.sh --restored --gui --package "$removePackage"
# Or deliberately keep settings, using Terminal:
# scripts/uninstall.sh --keep-settings --cli --package "$removePackage"
```

Both modes use that exact `*-remove.pkg`. The choices mean “I already restored” or “keep
settings,” not an automatic power operation. User state and the permanent
maintenance lock are retained. The wrapper never invokes a potentially older CLI.

Do not use an old private repair-enabled package as a normal update. See
[troubleshooting](troubleshooting.md) when a safety check refuses maintenance.
