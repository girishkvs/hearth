# Hearth 1.0.0

Prevent idle **system sleep** on battery or plugged in, from the menu bar,
Terminal, or a local browser page.

**Your display can still turn off and your session can still lock.** Version
1.0.0 does not change display sleep, screen savers, locking, or password protection.
Those controls are follow-up work, not part of this release.

![Hearth web controls showing sample battery and adapter settings](docs/images/ready.png)

*Actual 1.0.0 web UI with isolated sample data; no live settings or private URL.*

## Quick start

Requires macOS 13+; source builds need Xcode 26+ / Swift 6.2+. Review source before
authorizing installation.

```sh
git clone https://github.com/girishkvs/hearth.git
cd hearth
git checkout v1.0.0
scripts/prepare-release.sh
scripts/install.sh --gui                 # Native Installer
# Or explicitly install through Terminal:
# scripts/install.sh --cli
open /Applications/Hearth.app
```

The wrappers use the same versioned setup package. Default invocation only shows
guidance; `--cli` actually runs macOS Installer through user-authorized sudo.
Normal Hearth controls never invoke setup or request a password.

This is a **source-first MIT release**, not a notarized binary distribution.
Packages labeled `local` are unsigned and do not authenticate a publisher.
Use only a trusted artifact; see [installation](docs/installation.md) for downloaded
source/packages, checksum checks, update and removal.

## Use Hearth

Open **Hearth** from Applications, then click the **flame icon** in the menu bar.
Or run `open /Applications/Hearth.app` as your normal user; Spotlight is not needed.
Hearth has no Dock icon, and setup does not launch it automatically.
The main menu shows current settings and one primary action. Both power sources
are selected by default; choose a different target or timeout under **Advanced**.

**Keep awake** keeps the selected profiles awake while idle.
**Restore previous settings** restores only settings Hearth changed.
**Set sleep timeout**, in Advanced, saves a new timeout in minutes. Unconfirmed
settings disable changes until status is known; errors keep diagnostic detail
available without putting it in the everyday controls.

Setup installs a small helper and requires administrator approval. Everyday
controls do not ask for a password. If the helper is unavailable, Hearth shows
setup/repair instructions instead of prompting during a change.

### Terminal

```sh
hearth                                  # Actual settings and helper status
hearth on                               # Prevent idle sleep on both profiles
hearth on --power battery                # Battery only
hearth restore                          # Restore Hearth-managed settings
hearth sleep --minutes 10 --power adapter
hearth status --json
```

`--power` accepts `battery`, `adapter`, or `both`. `hearth off` is an alias for
`restore`, not a global promise that sleep is enabled. Timeouts must be positive
whole minutes; use `on` for zero. Run Hearth as your normal user.

If the command is not on PATH, use `/usr/local/bin/hearth`.

### Browser

```sh
hearth web
```

Hearth opens its controls on this Mac using an available localhost port.
Use **Keep awake** for the selected sources (Both by default). When Hearth has
saved settings, the main action becomes **Restore previous settings**. Power-source
selection, an explicit timeout, and detailed status are under **Advanced**.
Keep the private launch link to yourself. The web server runs only when requested.
Ctrl+C stops it without restoring power settings; closing the page does not stop
the server. `--no-open` prints the link without opening a browser.

## What Restore means

Hearth saves only settings it changes. A profile already set to never sleep stays
unmanaged; Hearth does not invent a previous timeout.

| Action | Battery | Adapter |
|---|---|---|
| Before Hearth | 1 minute | Already never |
| Prevent idle sleep | Never; original 1 saved | Unchanged |
| Restore | 1 minute | Still never |

An explicit sleep timeout becomes your new setting and clears the selected
restore record. Detected changes made by another tool are preserved.

## Documentation

| Guide | Contents |
|---|---|
| [Installation](docs/installation.md) | GUI and real CLI setup, source builds, updates and removal |
| [Usage](docs/usage.md) | Native/web screenshots, full CLI table and restore behavior |
| [Troubleshooting](docs/troubleshooting.md) | Helper readiness, uncertain operations and safe diagnostics |
| [Design](docs/design.md) | Shared core, authenticated helper, journal and privilege boundary |
| [Development](docs/development.md) / [Contributing](CONTRIBUTING.md) | Toolchain, focused tests and screenshot refresh |
| [Releasing](docs/releasing.md) | Version contract, clean-checkout artifacts, checksums and tag gate |
| [Changelog](CHANGELOG.md) / [1.0.0 notes](docs/releases/1.0.0.md) | Included behavior and validation limits |
| [Privacy](docs/privacy.md) / [Security](SECURITY.md) | Local data, network behavior and sensitive reporting |
| [License](LICENSE) / [Third-party notices](docs/third-party-notices.md) | MIT and dependency terms |

## Scope and saved settings

**The display may still turn off.** Settings persist after quitting or rebooting.
Hearth does not override lid closure, manual sleep, critical battery, or system
safety behavior. It does not change display sleep, hibernation, Low Power Mode,
UPS settings, or other applications' sleep assertions.

Saved restore state lives in `~/Library/Application Support/Hearth/state.json`.
If state is missing or damaged, Hearth does not guess a restore value. See
[the design](docs/design.md) for recovery behavior and technical details.

## License

[MIT License](LICENSE), copyright 2026 Girish Konda. The native Installer License
step uses the exact project license; dependency licenses and notices are separate.
