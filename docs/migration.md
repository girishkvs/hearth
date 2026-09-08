# Updating from Hearth 1.0.0 to 1.2.0

**Hearth 1.2.0 passed local update and LockOn/RestoreLock acceptance.**
Building or preparing packages does not itself
update the installed app/helper, migrate live state or change settings. Each
deployment needs explicit approval and the exact matching package. Never replace
individual binaries in the installed signed inventory.

## Active settings are preserved

You do not need to turn off a managed System override to retain it through an
update. Setup preserves per-user state and does not execute power commands.
After the approved update, the first 1.2.0 status/action reads the old state under
the shared lock and atomically upgrades valid state to schema 4. Schemas 2 and 3
from earlier unpublished candidates are also accepted.

| 1.0.0 record | 1.2.0 interpretation |
|---|---|
| Battery System original 1, applied 0, actual 0 | Same active System override: original 1, applied 0 |
| Adapter already 0, no restore record | Still unmanaged; no timeout invented |
| Pending System operation | Same intent; reconciled against actual System value |
| Missing power profile | Restore/pending record retained with a warning |
| No display history | Empty Display restore map, regardless of actual display timeout |

Schema 4 retains the old `profiles` map for System and `displayProfiles` for Display.
No Lock ownership or screen-saver baseline is invented for schema 1/2 records.
Schema 3 Lock records keep their legacy backend identity and recovery limits.
The September 9 installed schema-3-to-4 migration preserved the existing battery
System 0/original 1 record and introduced no Display or Lock ownership. Schema
1/2 cases and legacy Lock recovery paths also have isolated fixture coverage.
Display baselines are saved only when an explicit Display action or Lock's
disclosed dependency changes an observed nonzero timeout. Independent Display
restoration never clears System ownership.
Repeated activation preserves the first saved original for that setting/profile.
Externally changed values remain external: migration does not force a historical
snapshot back onto current settings.

Corrupt, future-version or invalid records block writes and remain untouched.
Atomic writes and the existing helper-held lock lease protect interruption and
concurrent clients across both settings. Do not delete the state or lock to clear
an error.

## Clients, helper, and scripts

Product version **1.2.0**, state/status schema **4**, root-helper IPC **2**, and
per-user Lock IPC **2** are distinct contracts. Authorization-policy
and installation formats retain their existing versions. New app, CLI and helper
payloads have no Automation entitlement. Verified installed legacy app-only grants
remain accepted for update/removal, not for new or staged payloads. Updating Hearth
does not reset or revoke any existing OS permission.

IPC 1 cannot express a Display setting. Mixed old/new helper protocols reject
operations and require an explicit matching update; there is no downgrade of a
Display request into a System write. Post-write replies with an incompatible or
malformed envelope remain indeterminate, preserving pending state. Exact enrolled
code hashes also mean a rebuilt client is not silently trusted by the installed
helper. Normal commands never invoke sudo, AppleScript or Installer as a fallback.

Existing `hearth on`, `restore`, `off`, and `sleep` continue to mean **System**.
Use `--setting display` explicitly. Old web requests omitting `setting` also mean
System; explicit invalid settings are rejected. Status JSON keeps `profiles` as
System and adds `displayProfiles` and per-record `setting`; scripts must honor
`schemaVersion` rather than interpreting Display entries as extra power profiles.
Schema 4 retains `idleLock` status without changing the System/Display arrays.
The internal `active` phase means configured settings, not immediate runtime adoption.

## Lock preferences and legacy recovery

New Lock operations use public CFPreferences with no Automation setup or permission.
CLI/web retain the verified app-only per-user service so all interfaces share one
serialized current-user writer. A matching app/CLI update is still required for
the new wire contract; helper power IPC is unchanged.

New records capture typed stored presence/value, effective timer, dictionary and
value sources, and context fingerprints. Original absence is restored by removing
the key, not writing an effective default. The engine defaults resource is read
at runtime; there is no hardcoded timer fallback.

If Hearth's stored timer is still zero but the captured non-target context has
changed, it keeps ownership and reports restore needed with restoration disabled.
A context-only mismatch is not proof of an external timer change or permission
to discard the baseline. No write or dependency release is performed; retain
the journal for review.

Prevent idle lock coordinates screen-saver idle delay with System and Display
awake on every available power profile. It borrows pre-existing awake settings,
including a managed battery System 0/original 1, without taking ownership of them.
One **Restore Lock** releases only settings acquired by Lock. Affected ordinary
controls show **Required by Lock** instead of silently changing its dependencies.
Password requirement, grace delay, manual lock and automatic logout are not changed.

The Lock plan and each component's pending state are durable before its write.
An interrupted power operation uses the existing helper-held lock/reconciliation
contract. Legacy Apple Events pending records remain quarantined: matching
readback must not clear their pending marker or authorize a blind retry. Confirmed
legacy timer acquisitions have no exact preference-presence baseline and remain
recovery-only rather than becoming CF records. Preserve the journal for review;
do not reset, discard or replay it to enable the new backend. Persistent settings do not
automatically restore on application exit or crash.

**Configured** is a settings/readback result, not immediate OS runtime proof.
macOS may adopt or restore the timer later. Completed installed-product acceptance,
the separate consumer diagnostic and the untested limits are in the
[release notes](releases/1.2.0.md).

## Approved update sequence

1. Before stopping anything, capture fresh full `pmset -g custom` output and a
   private byte-for-byte copy of the user's state. Inspect the installed version,
   inventory and active operations. These are deployment steps, not part of safe
   build-only work.
2. With approval, close only the installed Hearth app and its identified web
   server, keeping settings. Wait for outstanding operations; never restart the
   helper to break an active lease.
3. Run the exact reviewed 1.2.0 setup package through the GUI or direct-TTY
   wrapper with `--package`. Preserve actual exit status. Stop on refusal or uncertainty; do not
   weaken ownership, signing, Gatekeeper or other safety checks.
4. Compare full power values and raw state before starting new clients. Then
   inspect 1.2.0 status once to migrate/reconcile. Confirm every pre-existing
   System/Display record is retained and no new ownership is invented.
5. Only with live-test approval, perform one short LockOn/RestoreLock cycle through
   the installed client and native service. Compare exact timer presence/value,
   full power settings and prior ownership; restore only values acquired by Lock.
   Stop on external changes or uncertain completion, retaining records rather than retrying.

Testing physical idle behavior, manual lock/password preservation, power-source
switching or reboot is a separate user-visible exercise. Fake tests do not prove
these outcomes.

## Downgrade and removal

Hearth 1.0.0 and older unpublished candidates reject schema 4; they
must not be used to restore Lock state.
There is no automatic downgrade conversion. Keep a compatible 1.2.0 client/helper
available to restore Lock and both settings before any separately planned rollback. Never
copy a pre-update state snapshot over newer Display ownership or external changes.

Removal itself changes no power or screen-saver settings and keeps per-user state.
Use Restore Lock first, then restore remaining independently owned System and
Display settings if desired, or choose the native **Restore and quit** flow to
restore all Hearth-owned changes. Then use the existing
`--restored` removal flow. `--keep-settings` deliberately retains both.
