#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root/scripts/package-common.sh"
. "$root/scripts/installer-interface.sh"
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    installer_main remove "$@"
fi
