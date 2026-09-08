#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/package-common.sh"
refuse_root
version="$(release_version)"
printf '// Generated from VERSION by scripts/sync-version.sh.\npublic enum HearthVersion {\n    public static let current = "%s"\n}\n' \
    "$version" > "$root/Sources/HearthCore/HearthVersion.swift"
printf 'Generated Swift version %s from VERSION.\n' "$version"
