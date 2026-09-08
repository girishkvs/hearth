# Hearth design

## Components

One Swift package exposes `HearthCore` to the CLI, AppKit menu app, and embedded SwiftNIO HTTP handlers. `HearthIPC` connects the unprivileged core to a root-owned `HearthHelper`. UI code never shells out to the CLI. Only `hearth web` creates an HTTP listener.

`PowerCommandRunning` separates observation, helper readiness, and a batch of validated writes. Status reads use unprivileged Foundation `Process`; writes use authenticated XPC. Tests use fake runners and private temporary state directories. The parser matches the exact `sleep` key under `Battery Power:` and `AC Power:` and ignores UPS and unrelated keys. Missing, duplicate, or invalid values fail closed.

Normal operations have no authorization code path: no `sudo`, elevated AppleScript, automatic installation, or stored password. A missing, disabled, revoked, or incompatible service returns setup/repair-needed information. Actual settings remain readable.

## Installation and code identity

The selected local deployment is an explicitly authorized Apple Installer package, with an on-demand standalone launchd daemon in `/Library/LaunchDaemons`. The daemon executable and policy live in protected, root-owned locations. The app and CLI are installed under `/Applications/Hearth.app`, not executed as root. No root process executes source, plugins, Homebrew tools, or mutable executables from a user's worktree.

This is a deliberate supported alternative to `SMAppService`, not an attempt to register an ad-hoc bundle while claiming notarization. The installed macOS SDK's `SMAppService.h` documents that apps containing launch daemons must be notarized and explicitly preserves root-installed `/Library/LaunchDaemons`. This machine had no valid code-signing identity when the design was selected. The package is locally built and unsigned; it authenticates no publisher, and explicit installation trusts that local build. A future notarized distribution requires appropriate Developer ID credentials.

Final release clients and helper are signed with hardened runtime, without debugging or injection entitlements. After all binaries are finalized, the package records their exact CodeDirectory hashes in `/Library/Application Support/Hearth/authorization.plist`. Keeping that manifest outside the app avoids recursive mutual-signature dependencies. The policy reader validates the protected location and format; requirements are constructed from fixed signing identifiers and validated hashes, never accepted from an RPC caller.

Public macOS 13 `NSXPCListener.setConnectionCodeSigningRequirement` and `NSXPCConnection.setCodeSigningRequirement` enforce exact approved peer code. Accepted connections also receive the requirement before activation. Client connections select the privileged system Mach-service domain and require the enrolled helper identity. No private `auditToken` property or racy PID-to-path identity lookup is used. Kernel-provided effective UID identifies the caller for lease ownership; the request cannot claim a UID.

Pinning authorizes code, not a hidden per-user password session: users able to run the enrolled local CLI have access to its narrow capability. Ad-hoc identifiers alone are not trusted. Rebuilt or altered clients cannot silently re-enroll; updates replace the protected payload and manifest only through explicit maintenance consent. macOS repair, reinstall, or update approval is not bypassed.

## Privileged operation boundary

The wire protocol accepts a bounded batch of at most two distinct battery/adapter changes with validated numeric timeouts and observed prior values. The only power executable is `/usr/bin/pmset`, with fixed `-b`/`-c`, `sleep`, and numeric arguments. No shell, executable path, environment, launch arguments, caller UID, general file operation, or maintenance method is exposed over XPC.

The helper serializes batches, checks the actual expected value immediately before each write, and returns per-profile command results, including whether a command actually executed. The core still independently reads back settings and decides restore ownership. A definite skipped write clears its pending phase before reconciliation, so an external value that already equals the target does not become an invented Hearth baseline. Starting the helper, installing it, or checking readiness performs no power write.

The main process, HTTP server, and journal remain unprivileged. A transferred file descriptor is only a lock lease, not a path or authority claim: it must be a private regular file owned by the authenticated connection's UID. The helper does not read or write it and holds a duplicate until queued/running work finishes. Neither side explicitly unlocks the shared file description. Requests are bounded and never retried automatically after uncertain transport failure.

A permanent root-owned `operation.lock` separates power work from setup/removal. Helpers hold shared leases through queued work and child completion; maintenance requires an exclusive nonblocking lease and cannot kill an active request to proceed. The privileged backend uses public `posix_spawn` file actions to inherit both the user journal lease (fd 0) and root maintenance lease (fd 3). This deliberate exception to Foundation `Process` is necessary to retain both locks across helper death; command paths and arguments remain fixed. Unprivileged observation still uses Foundation `Process`.

The parent destroys its spawn configuration immediately after spawning, before draining output.
Otherwise its temporary duplicate of the pipe writer would prevent EOF after the child exits,
leaving a read stuck while both leases remain held. The child retains its own lock descriptors;
closing the parent's temporary spawn copies does not release those child leases.

## Journal

Version 1 stores a `profiles` map keyed by `battery` and `adapter`. A profile contains an optional `override` (`original`, `applied`) and optional `pending` (`action`, `original`, `applied`). An active override always has a positive original timeout and applied value zero. Pending explicit timeouts can exist without an override; they must never become invented restore baselines.

The lock is nonblocking and spans observation, reconciliation, journal save, helper work, read-back, and final save. A second client gets a busy error rather than waiting behind an active operation. Files are owner-only and checked for links and ownership. Writes use a same-directory exclusive temporary file, file sync, rename, and directory sync.

Closing a client's descriptor does not release the helper's duplicate lease. A timed-out RPC is indeterminate: the caller leaves the pending record intact rather than reading the old value and discarding it while work might still happen. After all workers release the lease, a later status call can safely reconcile the journal.

| Pending read-back | Recovery |
|---|---|
| Equals intended value | Finalize activation, or clear state after restore/explicit timeout |
| Equals pre-operation value | Discard pending phase, retain any prior override |
| Equals neither | Preserve actual value and remove stale ownership |
| Profile unavailable | Keep journal and warn |

Before applying, all selected profile journals are saved in one write. Results combine command exit status and per-profile read-back. An applied value with a failed/missing command acknowledgment is reported as a failure **with actual state retained truthfully**, not as no change. If read-back fails, the pending journal remains durable.

Status also reconciles interrupted records under the same lock. Corrupt or future-version state is never silently replaced; status can report actual values with a warning, but writes are blocked.

## Limits of observation

`pmset` has no compare-and-swap API and does not identify the writer. Hearth preserves external changes observable at reconciliation and at the helper's expected-value check. It cannot identify another tool writing the same value or prevent an unrelated tool from changing settings between that check and `pmset`. Hearth's locks and queue coordinate Hearth, not arbitrary external tools. These limitations are why status describes observed settings and saved ownership separately.

Low Power Mode is never modified. How a specific macOS release applies idle-sleep policy alongside Low Power Mode is a platform behavior to test with user approval, not a guarantee. Setting `sleep` to zero is not a promise to defeat all causes of system sleep.

## HTTP boundary

SwiftNIO parses HTTP on an IPv4 loopback listener. An unpredictable per-run token is placed in the launch fragment and required as a Bearer header for APIs. The exact Host/port is enforced; mismatched Origin is refused and power POST requires the server's origin. The embedded page uses no external assets. Body/header limits, connection limits, idle handling, and pipeline rejection prevent unbounded request queues. Core operations are dispatched off event loops.

The token is a local capability, not a remote login system. Anyone with the printed URL or equivalent access to the user's browser/process can use that session's enrolled helper capability. There is deliberately no second password prompt to compensate for a leaked token. The loopback, Host/Origin, token, bounded-request, CSP, and no-third-party-resource controls remain essential. Web code cannot install or repair the helper.

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

Isolated IPC and filesystem tests do not establish real Installer acceptance, system-domain activation, or reboot persistence. Those require a separately authorized installation on the target Mac. No security policy is weakened to make that step succeed.
