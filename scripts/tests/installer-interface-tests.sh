#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
. "$root/scripts/install.sh"
directory="$1"
stem="$(release_stem)"
setup="$directory/$stem-setup.pkg"
remove="$directory/$stem-remove.pkg"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/hearth-interface-tests.XXXXXX")"
trap 'rm -r "$temporary"' EXIT
record="$temporary/invocation"
fake_installer="$temporary/fake-installer"
printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "$HEARTH_TEST_RECORD"\nexit "${HEARTH_TEST_EXIT:-0}"\n' > "$fake_installer"
chmod 755 "$fake_installer"
export HEARTH_TEST_RECORD="$record"

installer_command() {
    if [ "$1" = /usr/bin/sudo ]; then
        [ "$2" = -- ] && [ "$3" = /usr/sbin/installer ] || return 99
        shift 3
        "$fake_installer" "$@"
    elif [ "$1" = /usr/bin/open ]; then
        shift
        "$fake_installer" "$@"
    else
        printf 'Unexpected installer executor.\n' >&2
        return 99
    fi
}

if installer_main setup --cli --package "$setup" </dev/null >"$temporary/no-tty" 2>&1; then exit 1; fi
grep -q 'direct interactive stdin, stdout and stderr' "$temporary/no-tty"
test ! -e "$record"
installer_has_terminal() { return 0; }

installer_main setup --cli --package "$setup"
printf '%s\n' -verboseR -pkg "$setup" -target / > "$temporary/expected"
cmp "$record" "$temporary/expected"
cp "$setup" "$temporary/package with spaces.pkg"
installer_main setup --cli --package "$temporary/package with spaces.pkg"
printf '%s\n' -verboseR -pkg "$temporary/package with spaces.pkg" -target / > "$temporary/expected"
cmp "$record" "$temporary/expected"
installer_main setup --gui --package "$setup"
printf '%s\n' -b com.apple.installer "$setup" > "$temporary/expected"
cmp "$record" "$temporary/expected"
installer_main remove --keep-settings --cli --package "$remove"
printf '%s\n' -verboseR -pkg "$remove" -target / > "$temporary/expected"
cmp "$record" "$temporary/expected"
installer_main remove --restored --open-installer --package "$remove"
printf '%s\n' -b com.apple.installer "$remove" > "$temporary/expected"
cmp "$record" "$temporary/expected"

export HEARTH_TEST_EXIT=73
code=0
installer_main setup --cli --package "$setup" >"$temporary/failure" 2>&1 || code=$?
test "$code" -eq 73
grep -q 'sudo/Installer exit 73' "$temporary/failure"
grep -q 'do not retry blindly' "$temporary/failure"
export HEARTH_TEST_EXIT=1
code=0
installer_main setup --cli --package "$setup" >"$temporary/cancelled" 2>&1 || code=$?
test "$code" -eq 1
grep -q 'sudo/Installer exit 1' "$temporary/cancelled"
unset HEARTH_TEST_EXIT
installer_main setup --cli --package "$setup" >"$temporary/success" 2>&1
grep -q 'sudo password entry is hidden' "$temporary/success"
grep -q 'completed (Installer exit 0)' "$temporary/success"
rm "$record"
if installer_main remove --cli --package "$remove"; then exit 1; fi
if installer_main setup --cli --gui --package "$setup"; then exit 1; fi
if installer_main setup --gui --verbose --package "$setup" >"$temporary/unsupported-verbose" 2>&1; then exit 1; fi
grep -q -- '--verbose requires --cli' "$temporary/unsupported-verbose"
if installer_main setup --verbose >"$temporary/missing-mode" 2>&1; then exit 1; fi
grep -q -- '--verbose requires --cli' "$temporary/missing-mode"
if installer_main setup --cli --verbose --verbose --package "$setup"; then exit 1; fi
if installer_main setup --cli --package "$remove"; then exit 1; fi
if installer_main setup --gui --package "$temporary/missing.pkg"; then exit 1; fi
ln -s "$setup" "$temporary/link.pkg"
if installer_main setup --cli --package "$temporary/link.pkg"; then exit 1; fi
test ! -e "$record"
installer_main setup --cli --verbose --package "$setup" >"$temporary/verbose" 2>&1
grep -q 'completed (Installer exit 0)' "$temporary/verbose"
rm "$record"
"$root/scripts/tests/installer-progress-tests.sh"
installer_main setup >/dev/null
test ! -e "$record"
printf 'HEARTH_INSTALLER_INTERFACE_TEST: PASS (fixed GUI/CLI argv, TTY guard, progress/result guidance, exit propagation; fake execution only)\n'
