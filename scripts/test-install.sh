#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/package-common.sh"
refuse_root
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hearth-installer-tests.XXXXXX")"
trap '/bin/rm -r "$temporary"' EXIT
for script in package-common.sh installer-interface.sh package-app.sh package-installer.sh capture-support-repair.sh install.sh uninstall.sh test-install.sh prepare-release.sh sync-version.sh; do
    /bin/bash -n "$root/scripts/$script"
done
for operation in setup remove; do
    /bin/sh -n "$root/Packaging/Installer/$operation/preinstall"
    /bin/sh -n "$root/Packaging/Installer/$operation/postinstall"
done
/usr/bin/xcrun swiftc -D HEARTH_INSTALLER_TESTS \
    "$root/Packaging/Installer/Inventory.swift" "$root/Packaging/Installer/Maintenance.swift" \
    "$root/Packaging/Installer/Installation.swift" "$root/Packaging/Installer/Repair.swift" \
    "$root/scripts/tests/InstallerTests.swift" "$root/scripts/tests/RepairTests.swift" "$root/scripts/tests/ReceiptTests.swift" \
    "$root/Packaging/Installer/main.swift" \
    -o "$temporary/tests"
"$temporary/tests" "$root" "$@"
