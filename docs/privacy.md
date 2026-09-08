# Privacy and local data

Hearth has no telemetry, analytics, account login, automatic updater or cloud
backend. Runtime power operations use local macOS commands and authenticated local
XPC. Building fetches the declared Swift package dependencies from GitHub; that is
build-time traffic, not runtime telemetry.

Your restore journal and lock live under
`~/Library/Application Support/Hearth/`. They contain per-profile original/applied
timeouts and pending phases, not passwords. The root-owned installation directory
contains code-identity hashes, an installed-file inventory and maintenance metadata.
Removal retains restore state and the permanent operation lock.

`hearth web` creates a foreground 127.0.0.1 server only when requested. The bundled
page has no third-party scripts, fonts or remote assets. It uses a new random token
per run; the page removes it from the visible URL and uses an Authorization header.
The token may be kept in tab-scoped sessionStorage. It is a local control capability,
not a password: anyone with it can use that server session's permitted controls.

Hearth never collects or stores administrator credentials. GUI setup uses Apple's
Installer; explicit Terminal setup uses the normal sudo prompt for the fixed
Installer operation. Everyday controls do not prompt. Do not paste private launch
links, credentials, raw unrelated logs or personal desktop screenshots into issues.

The compact Terminal installer keeps a bounded set of recent stdout diagnostics
in a private temporary directory, removed when the wrapper exits normally. Its
formatter never captures sudo input or authentication stderr. Native Installer
also writes its usual macOS installation log.

Documentation images use isolated sample data and actual app/resource rendering,
not a user's desktop or live settings. Refresh instructions are in
[contributing](../CONTRIBUTING.md).
