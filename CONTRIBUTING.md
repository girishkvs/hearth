# Contributing

Use macOS and Xcode 26+ / Swift 6.2+. Start from a clean checkout and resolve the
committed dependencies without upgrading them incidentally.

```sh
swift test --disable-automatic-resolution
.build/debug/HearthApp --smoke-test
scripts/test-package.sh --fixture
```

Tests use fake power, timer and policy backends, private state and harmless child processes. They
must never install a service, open an administrator prompt, or change host power
settings. Use the smallest relevant Swift test filter for code edits. Do not add
a live ON/Restore test to CI.

Keep system sleep separate from display/lock policy. New privileged operations
need an explicit allowlist, caller authentication, state/interruption tests and
independent review. Preserve existing user state and external changes.

## Documentation screenshots

```sh
scripts/capture-docs.sh
```

This renders the actual primary menu, native Advanced controls and web/Installer
resources with isolated sample data, without screen-recording permission or
installed-helper use. Primary-menu capture needs an active GUI context for the
sample app. Report an activation failure rather than bypassing it with desktop
capture, input synthesis or permission changes. Review
and commit only Hearth-only PNGs under `docs/images/`; no desktop, tokens, personal
paths, account details or hidden metadata. Caption Installer-resource previews
accurately—they are not screenshots proving an installation completed.

## Version and releases

Edit `VERSION`, run `scripts/sync-version.sh`, and add matching release notes.
The package manifest fails builds on generated-version drift. Do not change IPC
or state versions just to match a product version. See [releasing](docs/releasing.md).

Use a branch and a clear PR with motivation, behavior changes and commands actually
run. Do not include generated builds, private state or credentials. Sensitive
issues belong in the channel described by [SECURITY.md](SECURITY.md).
