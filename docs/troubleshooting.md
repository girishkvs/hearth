# Troubleshooting

## I cannot find Hearth after installation

Open Finder > Applications and double-click Hearth, or run
`open /Applications/Hearth.app` as your normal user. It is a menu-bar app: look for
the flame icon, not a Dock icon or ordinary application window. Setup does not
launch it automatically.

If Finder shows the bundle and it opens but Spotlight cannot find it, that is a
separate discovery/indexing issue, not proof the app is absent. Launch Services
registration and Spotlight metadata are different. An indexing-status error does
not by itself prove indexing is disabled. Hearth does not reset either database,
rebuild the system index, or change your Spotlight/privacy settings. Report the
exact result rather than reinstalling or globally reindexing blindly.

## The display went dark or the session locked

Hearth 1.0.0 prevents **idle system sleep**, not display sleep, screen savers or
automatic locking. Check macOS Lock Screen/Screen Saver settings separately.
Hearth does not disable password protection or synthesize user activity.

## Helper not ready

Run `hearth status` as your normal user and read the specific message. `hearth setup`
prints installation guidance. New/modified clients need explicit enrollment through
the matching reviewed package; no normal action elevates or silently reinstalls.

Do not disable Gatekeeper, SIP or signature validation. Unsigned downloaded packages
may be refused by macOS. Prefer a trusted local source build; record the actual
error before changing anything.

## Another operation is running

Wait for the current operation. Do not repeat ON/Restore blindly, delete lock/state
files, or restart a helper while a write may still execute. Preserve the raw journal
and current `pmset -g custom` output. A timed-out reply is not proof nothing changed.

If a process appears stuck, report its exact error, actual profile values, and
whether an operation was pending. Any cancellation/maintenance needs a deliberate
plan that verifies process identity and preserves current settings; do not restore
a historical snapshot just because it exists.

## Setup/update/removal was refused

Read the Installer log for this package and time only. Typical causes include a
foreign command/path, modified signed files, unsafe ownership/ACLs, an active
operation, or interrupted maintenance. Do not force overwrite or fabricate receipts.

Scripts-only installation can be successful without an Apple receipt plist/BOM.
Hearth verifies its protected manifest, complete inventory, signatures and ownership;
optional Apple receipts are checked if present. Unowned installations are not
accepted merely because a receipt is absent.

The old private installer could leave an empty support directory with an inherited
admin group. Normal creation now sets ownership through checked descriptors.
A fingerprint-bound repair exists only for a separately approved unchanged empty
directory; it is not a public release default and must never be a blanket chown.

## Terminal setup seems silent or the window was closed

Run `scripts/install.sh --cli` directly in one Terminal with no pipes or redirected
input/output. sudo password entry does not echo characters; press Return after
typing. One bar shows actual native progress and the current phase. A pause means
Installer has not reported new progress; Hearth does not fill the bar on a timer.
The final line reports the native exit status. Do not close the window while it
is running. `--verbose` selects raw diagnostics before an explicitly chosen run;
it does not authorize another attempt.

Closing Terminal can disconnect the installer client while macOS continues an
already-authorized package transaction. A missing final report proves neither
success nor cancellation. Do not retry blindly. Check that attempt's entries in
`/var/log/install.log`, then the installed version and read-only status. Preserve
current settings and restore state; do not run ON/Restore to diagnose installation.

## Useful read-only diagnostics

```sh
hearth --version
hearth status --json
/usr/bin/pmset -g custom
/usr/bin/pmset -g batt
```

For a report, include the command/error, OS and architecture, install/build method,
and relevant profile/state information. Redact usernames, paths you consider private,
browser launch tokens, credentials and unrelated logs. See [security](../SECURITY.md)
for sensitive reports. A report does not authorize anyone to change your settings.
