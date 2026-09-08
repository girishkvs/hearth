#!/bin/bash
set -euo pipefail
umask 022
root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/scripts/package-common.sh"
refuse_root
version="$(release_version)"
architecture="$(/usr/bin/uname -m)"
output="$root/dist/hearth-$version-macos-$architecture-local"
if [ "$#" -eq 2 ] && [ "$1" = "--output-dir" ]; then
    output="$2"
elif [ "$#" -ne 0 ]; then
    printf 'Usage: %s [--output-dir /absolute/new-directory]\n' "$0" >&2
    exit 2
fi
case "$output" in /*) ;; *) printf 'Output must be absolute.\n' >&2; exit 2 ;; esac
case "$architecture" in arm64|x86_64) ;; *) printf 'Unsupported architecture: %s\n' "$architecture" >&2; exit 1 ;; esac
require_new_output "$output"
cd "$root"
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
    printf 'Release preparation requires a clean committed checkout.\n' >&2
    exit 1
fi
if [ -n "${RELEASE_TAG:-}" ]; then
    if [ "$RELEASE_TAG" != "v$version" ] ||
       [ "$(git rev-parse "refs/tags/$RELEASE_TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
        printf 'Release tag must match VERSION and the checked-out commit.\n' >&2
        exit 1
    fi
fi
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all
/usr/bin/swift build -c release --disable-automatic-resolution \
    -Xswiftc -debug-prefix-map -Xswiftc "$root=/Hearth" \
    -Xswiftc -file-prefix-map -Xswiftc "$root=/Hearth"
bin="$(/usr/bin/swift build -c release --show-bin-path)"
if [ "$("$bin/hearth" --version)" != "Hearth $version" ]; then
    printf 'Built CLI version does not match VERSION.\n' >&2
    exit 1
fi
/bin/mkdir -p "$output"
"$root/scripts/package-installer.sh" --release-bin "$bin" --output-dir "$output"
"$root/scripts/test-package.sh" "$output"
stem="hearth-$version-macos-$architecture-local"
git archive --format=tar --prefix="hearth-$version/" HEAD | /usr/bin/gzip -n > "$output/hearth-$version-source.tar.gz"
/bin/cp "$root/docs/releases/$version.md" "$output/RELEASE-NOTES.md"
{
    printf 'Hearth %s\nCommit: %s\nArchitecture: %s\nSOURCE_DATE_EPOCH: %s\n' \
        "$version" "$(git rev-parse HEAD)" "$architecture" "$SOURCE_DATE_EPOCH"
    printf 'UNSIGNED LOCAL BUILD. Not notarized or publisher-authenticated.\n'
    /usr/bin/sw_vers -productVersion
    /usr/bin/xcodebuild -version
    /usr/bin/swift --version
} > "$output/BUILD-INFO.txt"
(
    cd "$output"
    /usr/bin/shasum -a 256 "$stem-setup.pkg" "$stem-remove.pkg" \
        "hearth-$version-source.tar.gz" BUILD-INFO.txt RELEASE-NOTES.md > SHA256SUMS.txt
    /usr/bin/shasum -a 256 -c SHA256SUMS.txt
)
printf 'Prepared %s from a clean checkout. Nothing was published or installed.\n' "$output"
