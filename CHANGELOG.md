# Changelog

## 1.2.0 - 2026-09-12

- Separate opt-in System and Display idle-sleep controls in the native menu,
  Terminal and local web page; battery and adapter remain selected by default.
- `--setting display` selects display operations; existing commands remain
  System-only. Each setting/profile owns its own original/applied timeout.
- Coordinated current-user **Prevent idle lock** and **Restore Lock** across all
  available profiles, with visible System/Display dependencies and borrowed ownership.
- Public CFPreferences current-user/current-host timer backend, with exact typed
  integer/absence restoration, engine dictionary/default provenance and context
  checks. No hardcoded timer fallback or unrelated preference shadowing.
- **Configured** labels distinguish settings/readback from OS runtime adoption.
  macOS may adopt or restore the timer later; logs are not a production status API.
- Removed obsolete Automation setup, permission callbacks, app entitlement and
  usage description. Existing OS permission state is neither reset nor revoked.
- App-only endpoint publication through a bounded same-user helper rendezvous;
  both peers of the final user connection remain independently authenticated.
- Atomic schema 1/2/3 migration to schema 4 preserves System/Display overrides and
  pending intent. Legacy Apple Events records remain recovery-only rather than
  acquiring invented preference-presence baselines.
- A context-only change while Hearth's stored timer remains zero retains its
  recovery record and blocks restoration; it is not mistaken for a released override.
- Typed, bounded IPC 2 setting/profile operations and explicit mixed-version
  update guidance, with existing helper identity and lock protections retained.
- Compact controls, updated sample-data native/web images, migration guidance,
  and separate setting/partial-failure/interruption coverage.

Lock controls idle triggers, not an unlocked-screen-off mode. Manual lock, password
requirements/grace delay, MDM and system safety remain outside its write scope.
Readiness requires verified absence of relevant idle restrictions; unknown policy
blocks the control, while recognized password-content-only rules remain intact.
Unconfirmed saver writes retain a quarantined journal because timeout
does not prove cancellation; no automatic uncertain-saver recovery is claimed.
Local acceptance covers a GUI update, migration and installed Lock configuration/
restoration on ARM64/macOS 26.6.2. Separate diagnostic evidence shows delayed
consumer adoption and restoration, not immediate/cross-OS behavior, reboot or
a 20-minute no-lock result. See the [acceptance record](docs/releases/1.2.0.md).
Local packages remain unsigned, with ad-hoc-signed code, and are not notarized.

## 1.0.0 — 2026-09-07

First source-first open-source release.

- Native menu-bar, Terminal, and optional localhost web controls for **system idle sleep**.
- Independent battery/adapter selection; Both is the default.
- Save and restore only settings changed by Hearth, with interruption recovery and external-change preservation.
- Explicit positive sleep timeouts, actual status, and JSON output.
- One explicit helper setup; normal controls use authenticated, narrowly scoped XPC without password prompts.
- Shared GUI and real command-line Installer paths for setup/update/removal, with strict ownership/signature/inventory checks.
- Compact primary controls, Advanced details, persistent actionable errors, and complete local build/release guidance.

Display sleep, screen saver, automatic locking, and password settings are unchanged.
Local installer packages are unsigned and not notarized. See
[release notes](docs/releases/1.0.0.md) for validation and platform limits.
