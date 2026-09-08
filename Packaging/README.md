# Local packaging contracts

These are **unsigned, local-trust Apple Installer artifacts**, not notarized SMAppService apps.
Explicitly opening the reviewed package and authorizing Apple Installer enrolls the exact local
app/CLI/helper CDHashes. An ad-hoc identifier does not prove a publisher.

## Build and checks

| Command | Contract |
| --- | --- |
| `scripts/package-app.sh [--release-bin ABS] [--output ABS/Hearth.app]` | Portable hardened app + CLI, resources, dependency licenses/notices/privacy. No helper installation. |
| `scripts/package-installer.sh [--release-bin ABS] [--output-dir ABS] [--repair-empty-support ABS]` | Produces setup/removal packages. Repair is opt-in and requires a local approved fingerprint file. |
| `scripts/capture-support-repair.sh ABS` | Read-only capture of the one eligible empty support directory into a new private local file. Does not perform or approve repair. |
| `scripts/test-install.sh` | Compiles first-party tests with direct `swiftc`; only an isolated fake filesystem and mocked service/signature commands. No SwiftPM build lock. |
| `scripts/test-package.sh --fixture` | Packages never-executed native stub binaries in a temporary directory; checks actual signatures, policy hashes, resources, absence of an Installer filesystem payload/BOM, and scripts. Removes its temporary artifacts. |
| `scripts/test-package.sh ABS` | Expands/checks real packages in that directory without installing or running their scripts. |
| `scripts/install.sh` | Guidance only by default. `--gui` opens the versioned setup package; `--cli` invokes native Installer through sudo. `--open-installer` aliases GUI. |
| `scripts/uninstall.sh --help` | Guidance only. Explicit removal needs `--restored` or `--keep-settings` plus `--gui`/`--cli`. No power CLI is ever executed; automatic `--restore` is refused. |

Build scripts reject root, unexpected/universal architectures, and existing output artifacts.
Product version comes from root `VERSION`; package filenames include version and native architecture.
`--release-bin` performs no SwiftPM invocation. Without it, package scripts build release first.
All app/CLI/helper signing happens on copied release files with hardened runtime.
App, CLI, helper and maintenance binaries have empty entitlements. The app has no
Automation usage description: the current-user timer backend uses public CFPreferences,
not Apple Events. CLI first, app second, separate helper last. Only then are the actual
`codesign --display --verbose=4` `CDHash=` values enrolled. Inventory SHA-256 hashes are separate
file-integrity checks; they are never used as code identity.

For removal with restoration, the user first restores Lock and independently owned
System/Display settings (or uses Restore and quit) in the compatible app after it reports the helper
ready, waits for success, then explicitly confirms `--restored --open-installer`. An absent or
incompatible helper requires repair or an explicit keep-settings choice. The wrapper intentionally
does not execute even a fixed-path CLI, so it cannot accidentally invoke an older
private development build's elevation path.

## Fixed installed paths

| Path | Type / permission |
| --- | --- |
| `/Applications/Hearth.app` | Root:wheel app tree; directories/executables 0755, ordinary files 0644 |
| `/Library/PrivilegedHelperTools/dev.girishkvs.hearth.helper` | Root:wheel 0755 regular file, not a worktree symlink |
| `/Library/LaunchDaemons/dev.girishkvs.hearth.helper.plist` | Root:wheel 0644; fixed `Program`, no arguments/environment, on-demand MachService |
| `/Library/Application Support/Hearth/authorization.plist` | Root:wheel 0644; protocol 2 / format 1, build ID, three lowercase 40-hex CDHashes |
| `/Library/Application Support/Hearth/install-receipt.plist` | Root:wheel 0644; complete allowlisted payload inventory |
| `/usr/local/bin/hearth` | Root:wheel symlink to `/Applications/Hearth.app/Contents/MacOS/hearth` |

Protected parents must be root-owned 0755, without ACLs or symlinks. Stock `/Applications`
root:admin 0775 and `/Library/Application Support` root:admin 0755 are accepted explicitly.
System ancestor flags and the fixed Apple `/var -> private/var` symlink are allowed.
The app itself remains root:wheel and non-writable to ordinary users.

New and staged payloads require root IPC protocol 2 and empty entitlements;
Automation and other extra grants are refused. Explicit maintenance may inspect
and replace/remove an existing protocol 1 or 2 installation only after the same
complete inventory, ownership and signature checks. This permits updating the
published 1.0.0 and prior unpublished candidates. A verified legacy app's exact former
Automation grant is accepted only for update/removal, never for a new or staged payload.
The user's existing macOS permission state is not changed.
The installer never migrates per-user state, requests Automation consent, or changes
power/saver values. Schema 1/2/3 migration to 4 belongs to the unprivileged core; numeric
legacy Apple Event ownership remains marked as legacy, and pending intent is not
converted into a confirmed preference write.

The helper's Lock rendezvous is an intentional exposed-interface extension: bounded
in-memory same-UID lookup and an exact-app-only anonymous publisher listener.
It does not execute preferences or Apple Events. Both peers authenticate independently
on the final native-user connection; endpoint possession is not authority. The Lock
protocol is version 2, separate from the unchanged root power protocol. No extra
launchd service or durable endpoint archive is installed.

## Directory creation and bounded repair

On macOS, `mkdir` inherits the parent's group even when Installer runs as root.
Successful exclusive directory creations are opened without following links, checked against
the created inode and safe metadata, then assigned root:wheel ownership and their intended
mode through that descriptor. New staging directories, lock files, and transaction records
also establish ownership explicitly. Existing directories are validated, never normalized
by the creation path; shared parent ownership, group, modes, flags, and ACLs are not changed.

The optional repair addresses only the empty `/Library/Application Support/Hearth` directory
left by a failed setup. Its machine-specific approval file belongs in local session artifacts,
not committed source. The installer requires the captured device, inode, birth time,
modification time, and change time; root:admin 0755; no flags, ACLs, links, or contents; and no
installed Hearth artifacts, receipts, service, lock, or transaction state. All checks occur
again during setup, not only when the approval file is captured.

Repair uses `fchown(checkedDescriptor, unchangedUID, wheelGID)`, without `chmod`, deletion, or
recursive changes. It preserves owner, mode, flags, ACLs, birth/modification times and shared
parent metadata. The inode's change time updates as a normal consequence of changing its
group. It revalidates the same inode and empty directory before proceeding with ordinary
setup. Changed or unrelated candidates cause refusal. A directory lease excludes another
repair while the permanent operation lock does not yet exist.

Building with `--repair-empty-support` copies the approved fingerprint only into the setup
package's trusted Scripts resources and selects a clear repair disclosure in Installation
Information. The ordinary package has no repair input and cannot adopt a wrong-group
directory. Opening and authorizing that exact repair-enabled package is a separate user
decision; neither capture nor packaging performs a system repair.

## Standard Installer pages and project license

The setup product title is `Hearth`, yielding the conventional **Install Hearth** window and
native **Welcome to the Hearth Installer** heading. Resource content does not repeat that
heading. Apple's host retains its **Installer** Dock/menu-bar name; a package cannot rename it,
and setting the product title to `Hearth Installer` would duplicate the native `Install` prefix.
Introduction and Read Me use restrained system typography and light/dark system colors.
Trust/build details live in Read Me, not the product introduction. A dedicated native License
step uses a byte-for-byte copy of the repository's
MIT `LICENSE`; it is never replaced with dependency notices or a custom EULA. The app bundle
also includes that project license, separately from `ThirdPartyLicenses`.

## Scripts-only packages: no ancestor metadata assumptions

Both package components use stock `pkgbuild --nopayload`. The built packages have no filesystem
`Payload`, no payload declaration/install root in `PackageInfo`, and no BOM. Signed artifacts and
their inventory are resources under the setup component's trusted `Scripts/payload` archive.
Apple Installer does not apply any payload directory metadata. No assumption about preservation
of a BOM `.` entry or existing `/Applications` metadata is needed.

The setup identifier is `dev.girishkvs.hearth.setup`; removal is
`dev.girishkvs.hearth.remove`. A successful scripts-only installation can appear in Apple's
install history with that identifier but have neither a receipt plist nor a BOM or `pkgutil`
registration. Hearth's protected manifest, complete file inventory, policy, and full signatures
remain mandatory ownership evidence for maintenance.

Apple receipts are additional evidence when present: expected identifiers, root ownership,
modes, links, and ACLs are validated. An orphan BOM, foreign receipt, or prototype component
receipt is refused. Missing Apple receipts never authorize adopting unowned files, and removal
only forgets Apple receipt IDs that were actually present and validated. No receipts are fabricated.

1. Preinstall validates the entire packaged source tree (allowlisted paths, no unexpected
   symlinks/ACLs, full signatures, actual CDHashes, and matching inventories). It validates all
   existing installed paths and receipts, briefly acquires the operation lock, and writes a
   protected maintenance transaction record. The old service and payload remain unchanged
   across the script boundary. This record is installer metadata, not a helper write barrier.
2. Postinstall acquires `LOCK_EX | LOCK_NB` and retains that same descriptor continuously through
   bootout, staging, replacement, verification, and bootstrap. An admitted helper batch makes it
   refuse before stopping the service. It repeats installed-state checks, stops the old service,
   then creates the fixed
   `/Library/Application Support/Hearth/install-staging` directory as root:wheel **0700**.
   Existing staging is refused as incomplete maintenance.
3. Fixed `/usr/bin/ditto --norsrc --noextattr --noacl` copies trusted extraction resources only
   into that private staging directory. Fixed `/usr/sbin/chown -h -R -P 0:0` protects this newly
   copied tree without following the CLI symlink. It never changes an existing shared directory.
   Staging stays inaccessible to ordinary users even while source ownership is being replaced.
4. The staged tree must pass exact root:wheel ownership/mode checks, full signature checks, and
   all hash/inventory checks. Only then are old verified Hearth entries removed individually.
5. Descriptor-relative `renameatx_np(..., RENAME_EXCL)` publishes only the five fixed artifact
   roots and the protected receipt. No copy writes through `/Applications/Hearth.app`; a raced
   foreign file/symlink causes refusal, never overwrite or following. Cross-volume rename failure
   also fails closed; there is no unsafe copy fallback.
6. Only known empty staging directories are removed with `rmdir`. Final fixed destinations are
   verified again, then the fixed launchd plist is bootstrapped and registration checked, still
   under the same exclusive lease and with the marker present. Only then is the marker cleared.
   Failures retain the marker/staging for explicit repair.

The Apple Installer maintenance executable runs only from its trusted Scripts extraction.
The actual `HearthHelper` daemon is **never executed there**: it is copied to its fixed protected
path, fully verified, and only then made available to launchd. App and CLI are never executed
as root. The installer never runs a power-setting command.

## Helper maintenance integration

**The helper and installer must implement this same contract before live installation is approved.**

- `/Library/Application Support/Hearth/operation.lock`: permanent root:wheel 0600 regular file.
  **Required helper behavior:** acquire nonblocking `flock(LOCK_SH)` before queue admission and
  retain SH through the queued/running batch and power child. An active exclusive lease makes
  helper availability and new operations unavailable.
  Both that descriptor and the caller's
  existing user `state.lock` lease must survive in the power child if the helper dies. Release the
  inherited shared lease by closing descriptors, never by `LOCK_UN` on the shared open-file
  description while a child might still use it.
  Installer uses `LOCK_EX | LOCK_NB`; a busy operation makes maintenance fail rather than killing
  it. All active setup/removal work happens inside one postinstall process holding one continuous
  EX descriptor. Its descriptor is close-on-exec and is not passed to any helper or power process.
  First setup creates the lock with `O_EXCL`; existing installations/removal require its existing
  inode. Neither the lock nor its parent is replaced, truncated, or deleted.
- `/Library/Application Support/Hearth/maintenance.plist`: root:wheel 0644 regular single-link file
  without ACLs, created with
  `O_EXCL | O_NOFOLLOW` and fsynced while the operation lock is held. Its Codable fields are
  `formatVersion: 1`, `operation: "setup" | "remove"`, and `buildIdentifier: String`, plus installer-only
  old/authorized inventories. Only the installer reads it for transaction and repair checks.
  The helper neither reads this record nor uses its existence as a write barrier.
- Preflight validates the old protected receipt, full file inventory, all three full signatures,
  enrolled code hashes, permissions, ACLs, and any present Apple Installer receipt paths before stopping
  an old service. A missing service is distinguished from permission/other launchctl failures.
- The record stays in place between preinstall and postinstall and throughout private staging,
  old-entry removal, and exclusive publication. Duplicate/interrupted maintenance fails closed.
  It is cleared only after complete final verification and bootstrap/registration (or completed
  removal), under EX. Helper requests may run between preparation and postinstall, while the
  old service and payload remain unchanged. Postinstall cannot begin active maintenance until
  every admitted shared lease, including surviving child leases, has closed.
- Removal preinstall prepares only. Removal postinstall revalidates, bootouts under its continuous
  exclusive lease, then deletes only listed files and empty listed app directories through
  no-follow directory descriptors. No recursive app removal, home-directory access, power command,
  user-state deletion, or operation-lock/journal reset.
- Failure retains the installer transaction record and reports incomplete/partial setup.
  There is deliberately no force mode or automated repair of unverified artifacts.

Production installer programs have no alternate-root, caller-command, caller-path, or environment
configuration. Standard pre/postinstall scripts only run the compiled tool from trusted package
extraction with a clean environment, and reject non-startup-volume targets. Test-only fake roots
are compiled under `HEARTH_INSTALLER_TESTS`, not present as production command options.

## Verification boundary

Fixture package builds and nonprivileged extraction validate the absence of filesystem payloads
and ancestor BOM metadata, artifact identities, and script contents. Isolated filesystem tests
exercise private staging, ownership validation, exclusive publishing (including raced symlinks),
and conservative failures. They do **not** prove live launchd lifecycle.
No installation, service registration,
admin dialog, helper execution, or power writes belong in the packaging test suite. Those require
separate user approval. Before any live test, confirm the continuous shared/exclusive lock contract. Parent
SwiftPM builds remain separate from direct-compiler packaging fixture tests.
