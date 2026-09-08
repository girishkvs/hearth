#!/bin/bash
set -euo pipefail
umask 077

root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/package-common.sh"
refuse_root
output="$root/dist/Hearth.app"
bin=""
while [ "$#" -gt 0 ]; do
    if [ "$#" -lt 2 ]; then
        printf 'Usage: %s [--output /absolute/path/Hearth.app] [--release-bin /absolute/path]\n' "$0" >&2
        exit 2
    fi
    case "$1" in
        --output) output="$2" ;;
        --release-bin) bin="$2" ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift 2
done
case "$output" in
    /*/Hearth.app) ;;
    *) printf 'Output must be an absolute path ending in /Hearth.app.\n' >&2; exit 2 ;;
esac
require_new_output "$output"
cd "$root"
if [ -z "$bin" ]; then
    # SwiftPM uses bare dependency caches. This override is limited to this command.
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
        /usr/bin/swift build -c release
    bin="$(/usr/bin/swift build -c release --show-bin-path)"
fi
case "$bin" in
    /*) ;;
    *) printf 'Release binary path must be absolute.\n' >&2; exit 2 ;;
esac
mkdir -p "$(dirname "$output")"
staging="$(mktemp -d "$(dirname "$output")/.hearth-package.XXXXXX")"
trap 'rm -r "$staging"' EXIT
app="$staging/Hearth.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -X "$root/Packaging/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $(release_version)" "$app/Contents/Info.plist"
cp -X "$root/LICENSE" "$app/Contents/Resources/LICENSE.txt"
cp -X "$bin/HearthApp" "$app/Contents/MacOS/HearthApp"
cp -X "$bin/hearth" "$app/Contents/MacOS/hearth"
/usr/bin/ditto --norsrc --noextattr --noacl "$bin/Hearth_HearthWeb.bundle" "$app/Contents/Resources/Hearth_HearthWeb.bundle"
/usr/bin/ditto --norsrc --noextattr --noacl "$bin/swift-nio_NIOPosix.bundle" "$app/Contents/Resources/swift-nio_NIOPosix.bundle"
mkdir "$app/Contents/Resources/ThirdPartyLicenses"
for dependency in swift-nio swift-atomics swift-collections swift-system; do
    cp -X "$root/.build/checkouts/$dependency/LICENSE.txt" "$app/Contents/Resources/ThirdPartyLicenses/$dependency.txt"
    if [ -f "$root/.build/checkouts/$dependency/NOTICE.txt" ]; then
        cp -X "$root/.build/checkouts/$dependency/NOTICE.txt" "$app/Contents/Resources/ThirdPartyLicenses/$dependency-NOTICE.txt"
    fi
done
find "$app" -type d -exec chmod 755 {} +
find "$app" -type f -exec chmod 644 {} +
chmod 755 "$app/Contents/MacOS/HearthApp" "$app/Contents/MacOS/hearth"
umask 022
sign_local_binary "$app/Contents/MacOS/hearth" dev.girishkvs.hearth.cli
# The app signature seals the already finalized nested CLI. No manifest is added inside the app.
require_native_binary "$app/Contents/MacOS/HearthApp"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime \
    --entitlements "$root/Packaging/EmptyEntitlements.plist" --identifier dev.girishkvs.hearth "$app"
/usr/bin/codesign --verify --strict "$app"
mv "$app" "$output"
printf 'Packaged %s (local ad-hoc signature; NOT notarized or publisher-authenticated).\n' "$output"
printf 'Portable UI/status only until explicit setup. No helper was installed or registered.\n'
