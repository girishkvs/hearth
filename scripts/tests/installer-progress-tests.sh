#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
. "$root/scripts/install.sh"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/hearth-progress-tests.XXXXXX")"
trap '/bin/rm -r "$temporary"' EXIT
replay="$root/scripts/tests/installer-progress-replay.txt"
formatter="$root/scripts/installer-progress.awk"

LC_ALL=C /usr/bin/awk -v interactive=1 -v columns=80 -f "$formatter" "$replay" > "$temporary/frames"
grep -q '\[##########----------\] 52%  Running package scripts' "$temporary/frames"
test "$(grep -o '52%' "$temporary/frames" | wc -l | tr -d ' ')" -eq 1
grep -q -- '--%  Preparing for installation' "$temporary/frames"
LC_ALL=C /usr/bin/awk -v interactive=0 -f "$formatter" "$replay" > "$temporary/phases"
test "$(grep -c '^Running package scripts$' "$temporary/phases")" -eq 1
test "$(wc -l < "$temporary/phases" | tr -d ' ')" -eq 2
if LC_ALL=C grep -q '[[:cntrl:]]' "$temporary/phases"; then exit 1; fi
printf 'installer:%%99.9\ninstaller:%%100.0\ninstaller:PHASE:The software was successfully installed.\n' |
    LC_ALL=C /usr/bin/awk -v interactive=1 -f "$formatter" > "$temporary/premature"
test ! -s "$temporary/premature"
printf 'installer:%%-1\ninstaller:%%101\ninstaller:%%no\n' |
    LC_ALL=C /usr/bin/awk -v interactive=1 -f "$formatter" > "$temporary/invalid"
test ! -s "$temporary/invalid"
printf 'installer:STATUS:Error - replay refused\n' |
    LC_ALL=C /usr/bin/awk -v diagnostics="$temporary/error-detail" -f "$formatter" >/dev/null
grep -q 'replay refused' "$temporary/error-detail"

for mode in success verbose failure interrupted; do
    code=0
    /usr/bin/script -q "$temporary/$mode" /bin/bash "$root/scripts/tests/installer-tty-fixture.sh" "$root" "$mode" >/dev/null || code=$?
    grep -q 'AUTH_TTY_REPLAY: direct input and stderr' "$temporary/$mode"
    case "$mode" in
        success|verbose)
            test "$code" -eq 0
            grep -q 'REPLAY_NATIVE_EXIT=0' "$temporary/$mode"
            grep -q 'Hearth setup completed (Installer exit 0)' "$temporary/$mode" ;;
        failure)
            test "$code" -eq 73
            grep -q 'REPLAY_NATIVE_EXIT=73' "$temporary/$mode"
            grep -q 'replay inventory refused' "$temporary/$mode" ;;
        interrupted)
            test "$code" -eq 130
            grep -q 'REPLAY_NATIVE_EXIT=130' "$temporary/$mode"
            grep -q 'Hearth setup failed (sudo/Installer exit 130)' "$temporary/$mode" ;;
    esac
done
grep -q 'installer:PHASE:' "$temporary/verbose"
if grep -q 'installer:PHASE:' "$temporary/success"; then exit 1; fi

installer_renderer() { return 2; }
installer_command() {
    /bin/sleep 0.1
    printf 'installer: Error - native replay failed after formatter exit\n'
    return 73
}
code=0
installer_cli setup /replay-only/setup.pkg false >"$temporary/renderer-failure" 2>&1 || code=$?
test "$code" -eq 73
grep -q 'Progress display stopped (exit 2)' "$temporary/renderer-failure"
grep -q 'native replay failed after formatter exit' "$temporary/renderer-failure"
installer_command() { return 0; }
installer_cli setup /replay-only/setup.pkg false >"$temporary/native-success" 2>&1
grep -q 'Progress display stopped (exit 2)' "$temporary/native-success"
grep -q 'Installer exit 0' "$temporary/native-success"

printf 'HEARTH_PROGRESS_REPLAY_TEST: PASS (real percentages, duplicate phases, unknown progress, errors, direct auth TTY, interruption, EOF and exact native exit; no sudo or installation)\n'
