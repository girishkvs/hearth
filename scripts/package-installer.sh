#!/bin/bash
set -euo pipefail
umask 022
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/package-common.sh"
refuse_root
stem="$(release_stem)"
output="$root/dist/$stem"
bin=""
repair=""
while [ "$#" -gt 0 ]; do
    if [ "$#" -lt 2 ]; then
        printf 'Usage: %s [--output-dir DIR] [--release-bin DIR] [--repair-empty-support APPROVAL.plist]\n' "$0" >&2
        exit 2
    fi
    case "$1" in
        --output-dir) output="$2" ;;
        --release-bin) bin="$2" ;;
        --repair-empty-support) repair="$2" ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift 2
done
case "$output" in
    /*) ;;
    *) printf 'Output directory must be absolute.\n' >&2; exit 2 ;;
esac
require_new_output "$output/$stem-setup.pkg"
require_new_output "$output/$stem-remove.pkg"
if [ ! -f "$root/LICENSE" ] ||
   [ -L "$root/LICENSE" ] ||
   [ ! -s "$root/LICENSE" ]; then
    printf 'A nonempty project LICENSE is required for the native Installer License step.\n' >&2
    exit 1
fi
if [ -z "$bin" ]; then
    cd "$root"
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
        /usr/bin/swift build -c release
    bin="$(/usr/bin/swift build -c release --show-bin-path)"
fi
case "$bin" in
    /*) ;;
    *) printf 'Release binary path must be absolute.\n' >&2; exit 2 ;;
esac
for executable in HearthApp hearth HearthHelper; do
    if [ ! -f "$bin/$executable" ]; then
        printf 'Missing release binary: %s/%s\n' "$bin" "$executable" >&2
        exit 1
    fi
done
architecture="$(/usr/bin/lipo -archs "$bin/HearthApp")"
case "$architecture" in
    arm64|x86_64) ;;
    *) printf 'Package requires one supported Mach-O architecture, not: %s\n' "$architecture" >&2; exit 1 ;;
esac
for executable in HearthApp hearth HearthHelper; do
    if [ "$(/usr/bin/lipo -archs "$bin/$executable")" != "$architecture" ]; then
        printf 'Inconsistent package architecture: %s must match %s.\n' "$executable" "$architecture" >&2
        exit 1
    fi
    require_native_binary "$bin/$executable"
done
/bin/mkdir -p "$output"
staging="$(/usr/bin/mktemp -d "$output/.hearth-installer.XXXXXX")"
trap '/bin/rm -r "$staging"' EXIT
payload="$staging/setup/payload"
support="$payload/Library/Application Support/Hearth"
/bin/mkdir -p "$payload/Applications" "$payload/Library/PrivilegedHelperTools" \
    "$payload/Library/LaunchDaemons" "$support" "$payload/usr/local/bin" "$staging/remove"
"$root/scripts/package-app.sh" --release-bin "$bin" --output "$payload/Applications/Hearth.app"
/bin/cp -X "$bin/HearthHelper" "$payload/Library/PrivilegedHelperTools/dev.girishkvs.hearth.helper"
/bin/chmod 755 "$payload/Library/PrivilegedHelperTools/dev.girishkvs.hearth.helper"
sign_local_binary "$payload/Library/PrivilegedHelperTools/dev.girishkvs.hearth.helper" dev.girishkvs.hearth.helper
/bin/cp -X "$root/Packaging/dev.girishkvs.hearth.helper.plist" "$payload/Library/LaunchDaemons/dev.girishkvs.hearth.helper.plist"
/bin/ln -s /Applications/Hearth.app/Contents/MacOS/hearth "$payload/usr/local/bin/hearth"
version="$(release_version)"
epoch="${SOURCE_DATE_EPOCH:-}"
if [ -z "$epoch" ]; then
    if git -C "$root" rev-parse --verify HEAD >/dev/null 2>&1; then
        epoch="$(git -C "$root" log -1 --format=%ct)"
    else
        epoch="$(/bin/date +%s)"
    fi
fi
if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
    printf 'SOURCE_DATE_EPOCH must be a Unix timestamp.\n' >&2
    exit 2
fi
build="$version.$(/bin/date -u -r "$epoch" +%Y%m%d%H%M%S)"
target="$architecture-apple-macosx13.0"
/usr/bin/xcrun swiftc -O -target "$target" -D HEARTH_PACKAGE_BUILD \
    "$root/Packaging/Installer/Inventory.swift" "$root/Packaging/Installer/main.swift" -o "$staging/inventory-tool"
"$staging/inventory-tool" "$payload" "$build"
/usr/bin/xcrun swiftc -O -target "$target" \
    "$root/Packaging/Installer/Inventory.swift" "$root/Packaging/Installer/Maintenance.swift" \
    "$root/Packaging/Installer/Installation.swift" "$root/Packaging/Installer/Repair.swift" \
    "$root/Packaging/Installer/main.swift" -o "$staging/installer-tool"
sign_local_binary "$staging/installer-tool" dev.girishkvs.hearth.installer
if [ "$(/usr/bin/lipo -archs "$staging/installer-tool")" != "$architecture" ]; then
    printf 'Maintenance tool architecture differs from the payload.\n' >&2
    exit 1
fi
for operation in setup remove; do
    /bin/cp -X "$staging/installer-tool" "$staging/$operation/installer-tool"
    /bin/cp -X "$root/Packaging/Installer/$operation/preinstall" "$staging/$operation/preinstall"
    /bin/cp -X "$root/Packaging/Installer/$operation/postinstall" "$staging/$operation/postinstall"
    /bin/chmod 755 "$staging/$operation/installer-tool" "$staging/$operation/preinstall" "$staging/$operation/postinstall"
done
/bin/cp -X "$support/install-receipt.plist" "$staging/setup/payload-receipt.plist"
if [ -n "$repair" ]; then
    case "$repair" in /*) ;; *) printf 'Repair input must be an absolute local path.\n' >&2; exit 2 ;; esac
    if [ ! -f "$repair" ] || [ -L "$repair" ]; then
        printf 'Repair approval must be a regular local file, not a link.\n' >&2
        exit 1
    fi
    /bin/cp -X "$repair" "$staging/setup/empty-support-repair.plist"
    /bin/chmod 644 "$staging/setup/empty-support-repair.plist"
    printf 'OPT-IN REPAIR: setup will require the exact approved empty support-directory fingerprint.\n'
fi
# Artifacts live only in the trusted Scripts archive. Installer applies no filesystem payload/BOM.
/usr/bin/pkgbuild --nopayload --identifier dev.girishkvs.hearth.setup --version "$version" \
    --scripts "$staging/setup" "$staging/Hearth-Setup-Component.pkg"
/usr/bin/pkgbuild --nopayload --identifier dev.girishkvs.hearth.remove --version "$version" \
    --scripts "$staging/remove" "$staging/Hearth-Remove-Component.pkg"
# productbuild only adds Apple's standard Installer consent/readme UI to the pkgbuild components.
/bin/mkdir "$staging/resources"
/bin/cp -X "$root/Packaging/Installer/Resources/Setup.html" "$staging/resources/Setup.html"
/bin/cp -X "$root/Packaging/Installer/Resources/Installation.html" "$staging/resources/Installation.html"
/bin/cp -X "$root/Packaging/Installer/Resources/Conclusion.html" "$staging/resources/Conclusion.html"
if [ -n "$repair" ]; then
    /bin/cp -X "$root/Packaging/Installer/Resources/RepairInstallation.html" "$staging/resources/Installation.html"
fi
/bin/cp -X "$root/Packaging/Installer/Resources/Remove.html" "$staging/resources/Remove.html"
/bin/cp -X "$root/LICENSE" "$staging/resources/License.txt"
/usr/bin/sed "s/@HEARTH_ARCHITECTURE@/$architecture/g" "$root/Packaging/Installer/Setup.xml" > "$staging/Setup.xml"
/usr/bin/sed "s/@HEARTH_ARCHITECTURE@/$architecture/g" "$root/Packaging/Installer/Remove.xml" > "$staging/Remove.xml"
/usr/bin/productbuild --distribution "$staging/Setup.xml" \
    --package-path "$staging" --resources "$staging/resources" "$staging/Hearth-Setup.pkg"
/usr/bin/productbuild --distribution "$staging/Remove.xml" \
    --package-path "$staging" --resources "$staging/resources" "$staging/Hearth-Remove.pkg"
/bin/mv "$staging/Hearth-Setup.pkg" "$output/$stem-setup.pkg"
/bin/mv "$staging/Hearth-Remove.pkg" "$output/$stem-remove.pkg"
printf 'Built %s/%s-setup.pkg and %s-remove.pkg.\n' "$output" "$stem" "$stem"
printf 'UNSIGNED LOCAL ARTIFACTS: not notarized, not publisher-authenticated. Review before explicitly opening Installer.\n'
printf 'No installation, service registration, administrator dialog, or power-setting change was performed.\n'
