#!/bin/sh
# lane.sh - deprecated alias of switch.sh, kept for one release (2.0.x).
#
# Transmogrify 2.0 renamed the operator switch script from lane.sh to
# switch.sh, so that "lane" means only a worker lane (scripts/lane.js).
# Every subcommand and exit code is unchanged; this alias prints one
# warning on stderr and runs switch.sh. It is removed in 2.1.
#
# Usage: lane.sh ARGS...   (exactly as switch.sh ARGS...)
set -u
printf 'lane.sh is deprecated and will be removed in 2.1: use switch.sh (same arguments).\n' >&2
exec sh "$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/switch.sh" "$@"
