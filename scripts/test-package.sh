#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/package-common.sh"
refuse_root
if [ "$#" -eq 1 ] &&
   [ "$1" != "--fixture" ]; then
    "$root/scripts/test-install.sh" --packages "$1"
    "$root/scripts/tests/installer-interface-tests.sh" "$1"
    exit 0
fi
if [ "$#" -ne 1 ]; then
    printf 'Usage: scripts/test-package.sh --fixture | /absolute/package-directory\n' >&2
    exit 2
fi
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hearth-package-test.XXXXXX")"
trap '/bin/rm -r "$temporary"' EXIT
/bin/mkdir "$temporary/bin"
/usr/bin/xcrun clang -mmacosx-version-min=13.0 "$root/scripts/tests/package-fixture.c" -o "$temporary/bin/HearthApp"
/bin/cp "$temporary/bin/HearthApp" "$temporary/bin/hearth"
/bin/cp "$temporary/bin/HearthApp" "$temporary/bin/HearthHelper"
/bin/mkdir -p "$temporary/bin/Hearth_HearthWeb.bundle" "$temporary/bin/swift-nio_NIOPosix.bundle"
/usr/bin/ditto --norsrc --noextattr --noacl "$root/Sources/HearthWeb/Resources" "$temporary/bin/Hearth_HearthWeb.bundle"
/bin/cp -X "$root/.build/checkouts/swift-nio/Sources/NIOPosix/PrivacyInfo.xcprivacy" \
    "$temporary/bin/swift-nio_NIOPosix.bundle/PrivacyInfo.xcprivacy"
"$root/scripts/package-installer.sh" --release-bin "$temporary/bin" --output-dir "$temporary/packages"
"$root/scripts/test-install.sh" --packages "$temporary/packages"
"$root/scripts/tests/installer-interface-tests.sh" "$temporary/packages"
architecture="$(/usr/bin/lipo -archs "$temporary/bin/HearthApp")"
case "$architecture" in arm64) other=x86_64 ;; x86_64) other=arm64 ;; *) exit 1 ;; esac
/usr/bin/xcrun clang -arch "$other" -mmacosx-version-min=13.0 \
    "$root/scripts/tests/package-fixture.c" -o "$temporary/bin/hearth"
if "$root/scripts/package-installer.sh" --release-bin "$temporary/bin" \
    --output-dir "$temporary/mixed-packages" >"$temporary/mixed-output" 2>&1; then
    printf 'Mixed-architecture package unexpectedly accepted.\n' >&2
    exit 1
fi
/usr/bin/grep -q 'Inconsistent package architecture' "$temporary/mixed-output"
test ! -e "$temporary/mixed-packages"
printf 'HEARTH_PACKAGE_FIXTURE_TEST: PASS. Stub executables were packaged, never run or installed; fixture artifacts removed.\n'
