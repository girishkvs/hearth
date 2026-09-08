#!/bin/bash
set -euo pipefail
umask 077
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/package-common.sh"
refuse_root
if [ "$#" -ne 1 ]; then
    printf 'Usage: %s /absolute/new/repair-approval.plist (read-only system inspection)\n' "$0" >&2
    exit 2
fi
case "$1" in /*) ;; *) printf 'Output path must be absolute.\n' >&2; exit 2 ;; esac
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hearth-repair-capture.XXXXXX")"
trap '/bin/rm -r "$temporary"' EXIT
/usr/bin/xcrun swiftc -D HEARTH_REPAIR_CAPTURE \
    "$root/Packaging/Installer/Inventory.swift" "$root/Packaging/Installer/Maintenance.swift" \
    "$root/Packaging/Installer/Installation.swift" "$root/Packaging/Installer/Repair.swift" \
    "$root/Packaging/Installer/main.swift" -o "$temporary/capture"
"$temporary/capture" "$1"
