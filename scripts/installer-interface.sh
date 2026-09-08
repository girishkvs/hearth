#!/bin/bash

installer_command() { "$@"; }

installer_has_terminal() { [ -t 0 ] && [ -t 1 ] && [ -t 2 ]; }

installer_renderer() { LC_ALL=C /usr/bin/awk "$@"; }

installer_read_progress() {
    local fallback="$1" result=0
    shift
    installer_renderer "$@" || result=$?
    if [ "$result" -ne 0 ]; then
        # This shell keeps the read end open even if the formatter exits early.
        if ! /usr/bin/tail -n 8 > "$fallback"; then
            printf 'Could not retain progress diagnostics; see /var/log/install.log.\n' >&2
            /bin/cat >/dev/null
        fi
    fi
    return "$result"
}

installer_cli() (
    local operation="$1" package="$2" verbose="$3" result=0 renderer_result=0
    local interactive=0 columns="${COLUMNS:-80}" temporary=""
    local -a codes
    [ ! -t 1 ] || interactive=1
    case "$columns" in ''|*[!0-9]*) columns=80 ;; esac
    if [ "$columns" -lt 30 ] || [ "$columns" -gt 240 ]; then columns=80; fi
    if [ "$verbose" = false ]; then
        if LC_ALL=C /usr/bin/awk -f "$root/scripts/installer-progress.awk" /dev/null >/dev/null; then
            :
        else
            result=$?
            printf 'Cannot start progress display; no installer was started.\n' >&2
            return "$result"
        fi
    fi
    printf 'Hearth %s %s (sudo password entry is hidden).\n' "$operation" "$(release_version)"
    if [ "$verbose" = true ]; then
        installer_command /usr/bin/sudo -- /usr/sbin/installer -verboseR -pkg "$package" -target / || result=$?
    else
        umask 077
        temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hearth-progress.XXXXXX")"
        trap '/bin/rm -r "$temporary"' EXIT
        trap ':' INT TERM
        # Only stdout is formatted. sudo input and authentication stderr retain the TTY.
        if installer_command /usr/bin/sudo -- /usr/sbin/installer -verboseR -pkg "$package" -target / |
            installer_read_progress "$temporary/unformatted" -v interactive="$interactive" -v columns="$columns" \
                -v diagnostics="$temporary/diagnostics" -f "$root/scripts/installer-progress.awk"; then
            codes=("${PIPESTATUS[@]}")
        else
            codes=("${PIPESTATUS[@]}")
        fi
        result="${codes[0]}"
        renderer_result="${codes[1]}"
        if [ "$interactive" -eq 1 ]; then printf '\r%*s\r' "$((columns - 1))" ''; fi
        if [ "$result" -ne 0 ] && [ -s "$temporary/diagnostics" ]; then
            /bin/cat "$temporary/diagnostics" >&2
        fi
        if [ "$result" -ne 0 ] && [ -s "$temporary/unformatted" ]; then
            /bin/cat "$temporary/unformatted" >&2
        fi
    fi
    if [ "$renderer_result" -ne 0 ]; then
        printf 'Progress display stopped (exit %s); the native Installer result follows.\n' "$renderer_result" >&2
    fi
    if [ "$result" -eq 0 ]; then
        printf 'Hearth %s completed (Installer exit 0).\n' "$operation"
    else
        printf 'Hearth %s failed (sudo/Installer exit %s). See /var/log/install.log; do not retry blindly.\n' "$operation" "$result" >&2
    fi
    return "$result"
)

validate_installer_package() (
    set -euo pipefail
    local package="$1" operation="$2" version
    version="$(release_version)"
    case "$package" in /*) ;; *) printf 'Package path must be absolute.\n' >&2; exit 2 ;; esac
    case "$package" in *$'\n'*|*$'\r'*) printf 'Package path cannot contain line breaks.\n' >&2; exit 2 ;; esac
    if [ ! -f "$package" ] || [ -L "$package" ]; then
        printf 'Missing package or symlink refused: %s\n' "$package" >&2
        exit 1
    fi
    local temporary metadata identifier built_version
    temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hearth-package-check.XXXXXX")"
    trap '/bin/rm -r "$temporary"' EXIT
    /usr/sbin/pkgutil --expand "$package" "$temporary/expanded" >/dev/null
    local component=Hearth-Setup-Component.pkg
    if [ "$operation" = remove ]; then component=Hearth-Remove-Component.pkg; fi
    metadata="$temporary/expanded/$component/PackageInfo"
    if [ ! -f "$metadata" ] || [ -L "$metadata" ]; then
        printf 'Package does not contain the expected Hearth component.\n' >&2
        exit 1
    fi
    identifier="$(/usr/bin/xmllint --nonet --xpath 'string(/pkg-info/@identifier)' "$metadata")"
    built_version="$(/usr/bin/xmllint --nonet --xpath 'string(/pkg-info/@version)' "$metadata")"
    if [ "$identifier" != "dev.girishkvs.hearth.$operation" ] ||
       [ "$built_version" != "$version" ]; then
        printf 'Expected Hearth %s package version %s; no installer was started.\n' "$operation" "$version" >&2
        exit 1
    fi
)

installer_usage() {
    printf '%s\n' \
        'Hearth installation uses the same reviewed package in GUI or Terminal.' \
        'scripts/install.sh --gui | --cli [--verbose] [--package /absolute/setup.pkg]' \
        'scripts/uninstall.sh --keep-settings | --restored --gui | --cli [--verbose] [--package /absolute/remove.pkg]' \
        '--cli shows compact real progress; --verbose keeps raw Installer diagnostics.' \
        '--open-installer is an alias for --gui. No mode selected means guidance only.' \
        'Packages are unsigned local builds, NOT notarized or publisher-authenticated.' \
        'Review their source/checksum before authorizing. Default paths use the current VERSION and architecture.' \
        'Restore in the ready Hearth app first if desired; --restored confirms that you already did so.' \
        'This wrapper never executes any CLI power command. Normal Hearth actions never invoke this wrapper.'
}

installer_main() {
    local operation="$1"
    shift
    refuse_root
    local mode="" choice="" package="" stem verbose=false
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help) [ "$#" -eq 1 ] || return 2; installer_usage; return 0 ;;
            --gui|--cli|--open-installer)
                [ -z "$mode" ] || { printf 'Choose only one installer mode.\n' >&2; return 2; }
                mode="$1"; [ "$mode" != "--open-installer" ] || mode=--gui
                shift ;;
            --keep-settings|--restored)
                [ "$operation" = remove ] && [ -z "$choice" ] || return 2
                choice="$1"; shift ;;
            --restore)
                printf 'Automatic restore is not supported; this wrapper never executes any CLI power command and no Installer was opened.\n' >&2
                return 2 ;;
            --package)
                [ "$#" -ge 2 ] && [ -z "$package" ] || return 2
                package="$2"; shift 2 ;;
            --verbose)
                [ "$verbose" = false ] || { printf 'Duplicate --verbose option.\n' >&2; return 2; }
                verbose=true; shift ;;
            *) printf 'Unknown option: %s\n' "$1" >&2; installer_usage >&2; return 2 ;;
        esac
    done
    if [ "$verbose" = true ] && [ "$mode" != --cli ]; then
        printf '%s\n' '--verbose requires --cli.' >&2
        return 2
    fi
    if [ -z "$mode" ]; then
        installer_usage
        [ "$operation" = setup ] && return 0
        return 2
    fi
    if [ "$operation" = remove ] && [ -z "$choice" ]; then
        printf 'Removal requires --keep-settings or --restored.\n' >&2
        return 2
    fi
    if [ "$mode" = --cli ] && ! installer_has_terminal; then
        printf 'Terminal installation requires direct interactive stdin, stdout and stderr.\nRun this command in one Terminal window without pipes or redirections; no installer was started.\n' >&2
        return 2
    fi
    stem="$(release_stem)"
    package="${package:-$root/dist/$stem/$stem-$operation.pkg}"
    validate_installer_package "$package" "$operation" || return "$?"
    if [ "$mode" = --gui ]; then
        printf 'Explicit %s using reviewed local package: %s\n' "$operation" "$package"
        installer_command /usr/bin/open -b com.apple.installer "$package"
    else
        installer_cli "$operation" "$package" "$verbose"
    fi
}
