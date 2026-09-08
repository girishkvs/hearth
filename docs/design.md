# Hearth design

## Components

One Swift package exposes `HearthCore` to the CLI, AppKit menu app, and embedded SwiftNIO HTTP handlers. `HearthIPC` connects the unprivileged core to a root-owned `HearthHelper`. UI code never shells out to the CLI. Only `hearth web` creates an HTTP listener.

`PowerCommandRunning` separates observation, helper readiness, and a batch of validated writes. Status reads use unprivileged Foundation `Process`; writes use authenticated XPC. Tests use fake runners and private temporary state directories. The parser matches the exact `sleep` and `displaysleep` keys under `Battery Power:` and `AC Power:` and ignores UPS and unrelated keys. Duplicate or invalid values fail closed. A missing display value is unavailable, never inferred from system sleep; system settings remain independently readable.

Normal operations have no authorization code path: no `sudo`, elevated AppleScript, automatic installation, or stored password. A missing, disabled, revoked, or incompatible service returns setup/repair-needed information. Actual settings remain readable.

## Installation and code identity

The selected local deployment is an explicitly authorized Apple Installer package, with an on-demand standalone launchd daemon in `/Library/LaunchDaemons`. The daemon executable and policy live in protected, root-owned locations. The app and CLI are installed under `/Applications/Hearth.app`, not executed as root. No root process executes source, plugins, Homebrew tools, or mutable executables from a user's worktree.

This is a deliberate supported alternative to `SMAppService`, not an attempt to register an ad-hoc bundle while claiming notarization. The installed macOS SDK's `SMAppService.h` documents that apps containing launch daemons must be notarized and explicitly preserves root-installed `/Library/LaunchDaemons`. This machine had no valid code-signing identity when the design was selected. The package is locally built and unsigned; it authenticates no publisher, and explicit installation trusts that local build. A future notarized distribution requires appropriate Developer ID credentials.

Final release clients and helper are signed with hardened runtime, without debugging or injection entitlements. After all binaries are finalized, the package records their exact CodeDirectory hashes in `/Library/Application Support/Hearth/authorization.plist`. Keeping that manifest outside the app avoids recursive mutual-signature dependencies. The policy reader validates the protected location and format; requirements are constructed from fixed signing identifiers and validated hashes, never accepted from an RPC caller.

Public macOS 13 `NSXPCListener.setConnectionCodeSigningRequirement` and `NSXPCConnection.setCodeSigningRequirement` enforce exact approved peer code. Accepted connections also receive the requirement before activation. Client connections select the privileged system Mach-service domain and require the enrolled helper identity. No private `auditToken` property or racy PID-to-path identity lookup is used. Kernel-provided effective UID identifies the caller for lease ownership; the request cannot claim a UID.

Pinning authorizes code, not a hidden per-user password session: users able to run the enrolled local CLI have access to its narrow capability. Ad-hoc identifiers alone are not trusted. Rebuilt or altered clients cannot silently re-enroll; updates replace the protected payload and manifest only through explicit maintenance consent. macOS repair, reinstall, or update approval is not bypassed.

## Privileged operation boundary

IPC version 2 accepts a bounded batch of at most two distinct battery/adapter
changes for one typed setting, with validated numeric timeouts and observed prior
values. Setting and profile enums allow only `system`/`display` and
`battery`/`adapter`. The only power executable is `/usr/bin/pmset`, with fixed
`-b`/`-c`, `sleep`/`displaysleep`, and numeric arguments. No shell, executable path,
environment, launch arguments, caller UID, general file operation, or maintenance
method is exposed over XPC. Version 1 cannot express Display: mixed versions fail
closed with update-required guidance, not a downgraded write or normal-action
authorization fallback. See [migration](migration.md).

The helper serializes batches, checks the actual expected value immediately before each write, and returns per-profile command results, including whether a command actually executed. The core still independently reads back settings and decides restore ownership. A definite skipped write clears its pending phase before reconciliation, so an external value that already equals the target does not become an invented Hearth baseline. Starting the helper, installing it, or checking readiness performs no power write.

The main process, HTTP server, and journal remain unprivileged. A transferred file descriptor is only a lock lease, not a path or authority claim: it must be a private regular file owned by the authenticated connection's UID. The helper does not read or write it and holds a duplicate until queued/running work finishes. Neither side explicitly unlocks the shared file description. Requests are bounded and never retried automatically after uncertain transport failure.

A permanent root-owned `operation.lock` separates power work from setup/removal. Helpers hold shared leases through queued work and child completion; maintenance requires an exclusive nonblocking lease and cannot kill an active request to proceed. The privileged backend uses public `posix_spawn` file actions to inherit both the user journal lease (fd 0) and root maintenance lease (fd 3). This deliberate exception to Foundation `Process` is necessary to retain both locks across helper death; command paths and arguments remain fixed. Unprivileged observation still uses Foundation `Process`.

The parent destroys its spawn configuration immediately after spawning, before draining output.
Otherwise its temporary duplicate of the pipe writer would prevent EOF after the child exits,
leaving a read stuck while both leases remain held. The child retains its own lock descriptors;
closing the parent's temporary spawn copies does not release those child leases.

## Journal

Version 4 keeps the `profiles` map for System and separate `displayProfiles`
map, each keyed by `battery` and `adapter`. A record contains an optional `override`
(`original`, `applied`) and optional `pending` (`action`, `original`, `applied`).
An active override always has a positive original timeout and applied value zero.
Pending explicit timeouts can exist without an override; they must never become
invented restore baselines. Every recovery, expected-value match and command result
is scoped to both setting and profile.

Valid version 1, 2 or 3 state migrates under the existing lock through an atomic version 4
save. Its `profiles` records remain System records, with unchanged original/applied
values and pending intent; `displayProfiles` starts empty for version 1 and is retained
for versions 2/3. No Lock record is invented by migration; existing schema 3 Lock
records retain legacy backend identity and recovery limits. A matching active battery
System override of applied 0/original 1 stays exactly that. Normal reconciliation
still preserves observed external changes or unavailable records. No display
baseline comes from migration, the System map, or a guessed default. An incompatible
helper blocks actions before loading/migrating state; a status read can migrate and
reconcile state but never writes power settings.

The lock is nonblocking and spans observation, reconciliation, journal save, helper work, read-back, and final save. A second client gets a busy error rather than waiting behind an active operation. Files are owner-only and checked for links and ownership. Writes use a same-directory exclusive temporary file, file sync, rename, and directory sync.

Closing a client's descriptor does not release the helper's duplicate lease. A timed-out RPC is indeterminate: the caller leaves the pending record intact rather than reading the old value and discarding it while work might still happen. After all workers release the lease, a later status call can safely reconcile the journal.

The following rules apply to power operations, not uncertain screen-saver writes:

| Pending power read-back | Recovery |
|---|---|
| Equals intended value | Finalize activation, or clear state after restore/explicit timeout |
| Equals pre-operation value | Discard pending phase, retain any prior override |
| Equals neither | Preserve actual value and remove stale ownership |
| Setting/profile unavailable | Keep that record and warn |

Before applying, all selected profile journals are saved in one write. Results combine command exit status and per-profile read-back. An applied value with a failed/missing command acknowledgment is reported as a failure **with actual state retained truthfully**, not as no change. If read-back fails, the pending journal remains durable.

Status also reconciles interrupted records under the same lock. Corrupt or future-version state is never silently replaced; status can report actual values with a warning, but writes are blocked.

## Limits of observation

`pmset` has no compare-and-swap API and does not identify the writer. Hearth preserves external changes observable at reconciliation and at the helper's expected-value check. It cannot identify another tool writing the same value or prevent an unrelated tool from changing settings between that check and `pmset`. Hearth's locks and queue coordinate Hearth, not arbitrary external tools. These limitations are why status describes observed settings and saved ownership separately.

Low Power Mode is never modified. How a specific macOS release applies idle-sleep policy alongside Low Power Mode is a platform behavior to test with user approval, not a guarantee. Setting `sleep` to zero is not a promise to defeat all causes of system sleep.

Apple's [pmset manual](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.1)
documents `sleep` and `displaysleep` as separate minute timers, with zero disabling
the timer and `-b`/`-c` selecting battery/charger. Hearth writes and restores these
settings independently. That is not proof of independent physical OS effects:
display state, assertions and system idle policy can interact, and policy may vary
by macOS/hardware. Keeping a display on can consume more energy. No live physical
display/system coupling experiment is claimed for 1.2.0.

## Coordinated Lock control

The native backend uses public CFPreferences for `com.apple.screensaver` /
`idleTime` at `kCFPreferencesCurrentUser` / `kCFPreferencesCurrentHost`. It uses
`CFPreferencesSetValue` and synchronizes that exact tuple, never a root preference
write, Apple Event, private restart, message port or notification.

The binding and effective lookup were established by inspecting the macOS 26.6.2
native engine and then a separately approved diagnostic. New loginwindow evidence
at 23:05:59 on September 8 showed `idleTime 0` and `targetUserIdle 0.0` after
several minutes. At 23:06:00 the diagnostic restored original timer absence and
only test-acquired Display values, preserving borrowed System zero/original-1
ownership and the exact full power/raw-state baseline. Authentication/grace were
unchanged. A bounded read-only follow-up observed `actualUserIdle 0.3` /
`targetUserIdle 1200.0` at 23:16:18.309 PDT after normal user activity, establishing
consumer return to the engine default. No extra setter, restart or fake input was
used. This one-Mac/cycle result establishes delayed adoption and restoration, not
immediate/cross-macOS behavior or a 20-minute no-lock result. Separately, the corrected
candidate's GUI update, schema-3-to-4 migration and installed CLI-to-native
LockOn/RestoreLock cycle passed on September 9, preserving exact timer absence,
power settings and prior ownership. See [release evidence](releases/1.2.0.md).

`ScreenSaverConfiguration` separates exact stored value (`absent` or typed
`integer`) from effective seconds, dictionary source, value source and a context
fingerprint. Effective lookup selects the first nonempty dictionary in this order:

1. Current user / current host.
2. Current user / any host.
3. Any user / any host.

Only after choosing that dictionary does a missing key fall back to the registered
engine defaults resource:
`/System/Library/Frameworks/ScreenSaver.framework/Versions/A/Resources/EngineDefaults.plist`.
Hearth reads and validates the installed resource; **there is no hardcoded 1200**.
This is not per-key `CFPreferencesCopyAppValue` fallback. Absence is not zero.

The backend checks the captured context before writing and after synchronization.
Creating or removing a current-host key can change dictionary selection. An empty
dictionary transition is allowed only when all effective non-idle values stay
identical; it refuses operations that would shadow unrelated fallback/security
values. The fingerprint covers every scoped non-target value and the resource.
The journal keeps backend identity and configuration fingerprints. Restoration uses the exact
original typed value or removes the key for original absence; it does not store an
effective default in place of absence or overwrite changed context blindly.

**Configured** describes verified settings/readback, not the physical screen or
immediate OS runtime adoption. **macOS may adopt or restore the timer later.**
Historical log evidence is not a production status API. No log parsing or user
screen-saver configuration is required for ordinary operation.

Lock controls actual idle triggers, not a magic session exemption or fake user
activity. One current-user action coordinates System and Display idle timeouts on
all available power profiles with the user's screen-saver idle delay. Separate
System/Display actions remain independent when not required by Lock.

No Automation permission/setup is needed. The obsolete app entitlement and usage
description are removed, without resetting or revoking user OS permission state.
Earlier System Events getter failure explains the backend change, not a current
setup requirement. Legacy Apple Events records retain their own recovery limits.

Management is not limited to one forced preference. Apple's password-policy
[`maxInactivity`](https://github.com/apple/device-management/blob/67045e2fa06f528b196c01edee6a8bf88b844beb/mdm/profiles/com.apple.mobiledevice.passwordpolicy.yaml#L88-L107)
is translated into screen-saver settings on macOS. `CFPreferencesAppValueIsForced`
and `UserDefaults.objectIsForced` provide supported key/domain-specific checks,
but a false result for one key does not prove that translated limits are absent.
The implemented readiness path requires positive evidence of no relevant idle
restriction: system-wide no configuration profiles; no DEP/MDM enrollment;
local-only authentication search; separately read user and node OpenDirectory policies;
no local user/group/computer MCX data; and no forced saver preference or automatic
logout across the relevant global user/host scopes. Unknown, malformed or unreadable
evidence fails closed. Only a PasswordContent rule with the known identifier/content/
optional localized-description structure and a single `policyAttributePassword MATCHES`
quoted literal is recognized as unrelated. Its predicate is neither compiled nor
evaluated. Parameters, compound expressions, functions, other attributes and nonempty
authentication/password-change categories remain blocked. The policy remains in place;
the result says no relevant idle restriction, not that the account has no policy.
Localized descriptions are inert text with string-map type and aggregate byte-limit
handling, not a locale-count limit or an idle-policy condition.

A small typed Objective-C bridge preserves the public OD query's nullable dictionary
and NSError independently. A nil result with no error is recorded as no explicit
policies returned for that layer; it never waives inherited node, MCX or other checks.
An actual NSError or malformed result remains unavailable. The public CF implementation's
successful response path maps CFNull to NULL; Swift's nonoptional throwing import had
turned this absence into an unhelpful GenericObjCError. No such error is broadly caught
and assumed to mean empty policy.

A profile is not assumed irrelevant merely because it lacks
one ScreenSaver key. This conservative policy intentionally excludes managed or
otherwise unverified configurations. Password/grace and logout policies are never
written. A separately approved target diagnostic confirmed the current-user absent/
no-error OD result and the inherited password-content-only rule without changing either.
This is evidence for that configuration, not acceptance of managed configurations.

### Ownership and uncertainty

The optional schema 4 `lockOverride` stores the transaction phase, planned power
dependencies, typed saver baseline, backend/context and pending/applied/released flags. A pre-existing
zero setting is borrowed, including its existing ordinary Hearth restore record.
Only positive timeouts changed by Lock are acquired. The complete plan is durable
before any component write; every nested power operation checks the planned
original against the same observation used for its helper precondition and journal.
Observed external timer changes can release stale ownership. A context-only
mismatch while Hearth's stored timer remains zero does not: the journal and
dependencies stay retained, status is `needsRestore`, and `canRestore` is false.
No write or release is authorized by that context mismatch.

One **Restore Lock** releases only acquired values, preserving borrowed settings
and detected external changes. Ordinary actions on affected profiles are blocked
with **Required by Lock** and a direct Restore Lock affordance. A partial activation
or restoration remains visible and retained, not silently rolled back or retried.
Native Restore and quit first releases Lock, then independently owned overrides.

The existing file lock covers the entire coordinated operation. Power children
retain the helper's lock lease; their pending state uses normal later reconciliation.
Legacy Apple Events are different: timeout, interruption or sender death does not prove
their setter cannot execute later. A legacy pending saver write remains quarantined
even when readback matches the old or intended value. Definite non-dispatch clears
pending for a new operation; only a confirmed successful reply followed by typed
readback establishes configured settings. Confirmed legacy timer acquisitions
without exact preference-presence baselines remain recovery-only, not converted
to CF acquisitions.
No automatic uncertain-saver recovery barrier is claimed from a PID, process exit,
elapsed time or repeated reads. Preserve the journal for explicit recovery rather
than deleting it. Persistent settings do not disappear on crash or quit.

The client combines a native observation with a newer local journal/power/helper
read. It must not reuse Configured or writable readiness when those disagree. New
pending saver state always wins over an older configured reply; disappeared/restored
ownership, changed dependencies, new profiles, helper failure or untrusted state
invalidate stale claims while retaining trusted originals. A subsequent consistent
refresh can restore normal eligibility. This is not an atomic snapshot of arbitrary
external tools or a way to infer unobserved saver changes.

### Per-user service and helper rendezvous

CLI/web use `HearthLockIPC` so the native app is one serialized current-user writer.
It hosts a bounded typed status/on/restore interface; authorization is not an IPC
operation. Both peers are code-pinned, with same-user kernel credentials checked.
Status does not launch Hearth; an explicit Lock action may open only the verified
installed app through Launch Services. No action is retried after uncertain dispatch.
The app refuses normal termination while accepted service work is outstanding.

`NSXPCListenerEndpoint` can be transferred over XPC but cannot be file-archived
with `NSKeyedArchiver`. The helper therefore exposes a small in-memory rendezvous:
an app-only, exact-code-pinned anonymous publication listener and same-UID lookup
for enrolled clients. UID comes from connection credentials; there is no caller UID,
destination path or durable endpoint file. Registration lifetime follows its
publisher connection, and generation-safe cleanup cannot remove a newer replacement.
Possession of an endpoint does not authorize the final connection.

This is an intentional privileged-interface expansion, not a preference service.
The helper never sends Apple Events, reads/writes saver preferences or executes the
published endpoint. Registration/connection limits and independent peer checks remain
essential. Tests transfer real anonymous XPC endpoints without using installed services.

The accepted candidate's installed configuration/restoration path and separate
delayed consumer observations are recorded in the release notes. Further physical
idle tests, reboot or broader platform validation need separate approval.
An unlocked display-off mode is not promised:
Apple's [Lock Screen settings](https://support.apple.com/guide/mac-help/change-lock-screen-settings-on-mac-mh11784/mac)
tie the unchanged password requirement to screen-saver initiation or display-off.

Display-always-on must never be presented as preventing every lock. The control
surfaces its System/Display dependencies and must not weaken
`askForPassword` or its delay, auto-unlock, fake activity, override manual lock,
or bypass managed configuration.

## HTTP boundary

SwiftNIO parses HTTP on an IPv4 loopback listener. An unpredictable per-run token is placed in the launch fragment and required as a Bearer header for APIs. The exact Host/port is enforced; mismatched Origin is refused and power POST requires the server's origin. The embedded page uses no external assets. Body/header limits, connection limits, idle handling, and pipeline rejection prevent unbounded request queues. Core operations are dispatched off event loops.

The token is a local capability, not a remote login system. Anyone with the printed URL or equivalent access to the user's browser/process can use that session's enrolled helper capability. There is deliberately no second password prompt to compensate for a leaked token. The loopback, Host/Origin, token, bounded-request, CSP, and no-third-party-resource controls remain essential. `POST /api/lock` has the same authenticated same-origin boundary as power requests and accepts only on/restore. Web code cannot install/repair the helper or grant Automation permission.

## Distribution boundary

Packaging produces hardened, locally ad-hoc signed binaries and an unsigned local setup package. Setup/maintenance use fixed protected destinations, verify installed content, and refuse collisions. Removal checks ownership and inventory, offers helper-backed restoration first, and retains per-user state. It does not publish, notarize, change shell startup, or auto-launch the UI/web server. The approved system helper is available on demand after reboot without a new prompt for each action.

The package is scripts-only (`pkgbuild --nopayload`). Its trusted Scripts archive contains the compiled installer coordinator and signed artifacts, not a filesystem payload/BOM that could reset shared ancestor metadata. The coordinator copies only into protected private staging, validates it, then publishes fixed destinations using descriptor-relative exclusive renames. It never recursively copies or changes ownership through a mutable `/Applications/Hearth.app` destination. An external manifest supplies full file inventory because script-created artifacts have no payload BOM. See [packaging contracts](../Packaging/README.md) for fixed paths, maintenance leases, interruption handling, and removal confirmation.

The Apple install-history entry is not treated as a package receipt. Scripts-only installation
may leave no Apple receipt files at all. Maintenance still requires the protected Hearth
manifest, matching full inventory and policy, and all code signatures. If Apple receipt files
exist, their metadata and identifiers are checked; orphan or foreign entries are refused.
Removal never asks `pkgutil` to forget an absent receipt.

## Platform references and validation boundary

- [Apple: NSXPC peer requirements](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:))
- [Apple TN3127: code-signing requirements, including cdhash](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
- [Apple: creating launch daemons and agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- Installed SDK: `ServiceManagement.framework/Headers/SMAppService.h` (daemon notarization and standalone launchd alternative); `Foundation.framework/Headers/NSXPCConnection.h` (macOS 13 public peer checks).
- Installed `pkgbuild(1)`, `launchctl(1)`, and `launchd.plist(5)` describe explicit root installation, payload ownership, and absolute `Program` requirements.

Isolated IPC and filesystem tests are not substitutes for installed acceptance.
The completed 1.2.0 GUI update and product cycle establish the local result described
in the release notes; they do not establish reboot persistence or the broader
platform/policy matrix. No security policy was weakened for acceptance.
