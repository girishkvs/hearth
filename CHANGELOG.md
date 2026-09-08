# Changelog

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
