#!/bin/bash

release_version() {
    local version
    IFS= read -r version < "$root/VERSION"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf 'VERSION must contain a three-part numeric release version.\n' >&2
        exit 1
    fi
    printf '%s\n' "$version"
}

release_stem() {
    printf 'hearth-%s-macos-%s-local\n' "$(release_version)" "$(/usr/bin/uname -m)"
}

refuse_root() {
    if [ "$(/usr/bin/id -u)" -eq 0 ]; then
        printf 'Run this command as your normal user; only explicit installation requests authorization.\n' >&2
        exit 1
    fi
}

require_native_binary() {
    local target="$1" architecture
    architecture="$(/usr/bin/lipo -archs "$target")"
    if [ "$architecture" != "$(/usr/bin/uname -m)" ]; then
        printf 'Refusing non-native or universal artifact: %s (%s).\n' "$target" "$architecture" >&2
        exit 1
    fi
}

sign_local_binary() {
    local target="$1" identifier="$2"
    require_native_binary "$target"
    /usr/bin/codesign --force --sign - --timestamp=none --options runtime \
        --entitlements "$root/Packaging/EmptyEntitlements.plist" --identifier "$identifier" "$target"
    /usr/bin/codesign --verify --strict --all-architectures "$target"
}

require_new_output() {
    if [ -e "$1" ] ||
       [ -L "$1" ]; then
        printf 'Refusing to overwrite %s. Select a new output location.\n' "$1" >&2
        exit 1
    fi
}
