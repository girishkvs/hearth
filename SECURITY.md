# Security

For a potential vulnerability, email **girish.sai1@gmail.com** with the affected
version, impact and a minimal reproduction. Do not include passwords, private web
tokens or unrelated personal data. Do not post an exploitable issue publicly
before the maintainer can assess it. No response-time guarantee is implied.

GitHub private vulnerability reporting is not assumed enabled. It can be used
only after the repository exists and that feature is explicitly enabled.

Hearth's privileged boundary is intentionally narrow: approved code identities,
battery/adapter idle-system-sleep values, bounded requests and protected ownership.
Normal controls do not elevate. Report any path that bypasses those restrictions.
Unsigned local packages do not authenticate a publisher; checksum integrity is
not notarization or signing trust.

Do not weaken macOS security policy, disable password protection, fabricate
receipts, or run destructive/live power experiments while preparing a report.
