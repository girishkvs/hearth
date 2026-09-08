#!/bin/bash
set -euo pipefail
root="$1"
. "$root/scripts/install.sh"
mode="$2"
verbose=false
if [ "$mode" = verbose ]; then verbose=true; fi

installer_command() {
    [ "$1" = /usr/bin/sudo ] && [ "$2" = -- ] && [ "$3" = /usr/sbin/installer ] || return 99
    [ -t 0 ] && [ -t 2 ] || return 98
    if [ "$verbose" = true ]; then [ -t 1 ] || return 97; else [ ! -t 1 ] || return 96; fi
    printf 'AUTH_TTY_REPLAY: direct input and stderr; no password requested.\n' > /dev/tty
    if [ "$mode" = interrupted ]; then
        /bin/sh -c 'printf "installer: Error - interrupted replay\n"; kill -INT "$$"; exit 99'
        return "$?"
    fi
    /bin/cat "$root/scripts/tests/installer-progress-replay.txt"
    if [ "$mode" = failure ]; then
        printf 'installer: Error - replay inventory refused\n'
        return 73
    fi
    /bin/sleep 0.1
    printf 'installer:PHASE:Finishing installation...\ninstaller:%%100.000000\ninstaller:PHASE:The software was successfully installed.\n'
}

result=0
installer_cli setup /replay-only/setup.pkg "$verbose" || result=$?
printf 'REPLAY_NATIVE_EXIT=%s\n' "$result"
exit "$result"
