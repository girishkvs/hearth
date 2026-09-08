#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/package-common.sh"
refuse_root
cd "$root"
mkdir -p docs/images
temporary="$(mktemp -d "${TMPDIR:-/tmp}/hearth-docs-capture.XXXXXX")"
trap 'rm -r "$temporary"' EXIT
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all
HEARTH_WEB_PREVIEW_DIR="$temporary" HEARTH_INSTALLER_PREVIEW_DIR="$temporary" \
    /usr/bin/swift test --disable-automatic-resolution --filter 'HearthPageTests|InstallerPageTests'
/usr/bin/swift build --disable-automatic-resolution --product HearthApp
.build/debug/HearthApp --capture-docs "$temporary"
for image in native-menu-default native-menu-active ready advanced keeping-awake introduction-light read-me-dark first-launch-light terminal-progress-dark; do
    cp "$temporary/$image.png" "$root/docs/images/$image.png"
done
/usr/bin/swift "$root/scripts/strip-image-metadata.swift" "$root"/docs/images/*.png
printf 'Updated actual sample-data UI captures; no installed process or power setting was used.\n'
