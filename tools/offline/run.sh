#!/bin/sh
# Runs every offline check. Needs a real Lua 5.1 interpreter -- the game's own version -- so that
# anything these accept is something the client will accept too:
#
#   apt-get install lua5.1     (or: brew install lua@5.1)
#
# Usage: sh tools/offline/run.sh        (from anywhere; RECK_ROOT overrides the repo path)
set -e
here=$(cd "$(dirname "$0")" && pwd)
RECK_ROOT=${RECK_ROOT:-$(cd "$here/../.." && pwd)}
export RECK_ROOT

echo "== luac -p =="
for f in $(find "$RECK_ROOT" -name '*.lua' -not -path '*/.git/*' -not -path '*/tools/*' | sort); do
	luac5.1 -p "$f" || exit 1
done
echo "  all files parse under Lua 5.1"
echo

status=0
for t in slice graph buffs analysis windows load; do
	echo "== $t =="
	if (cd "$here" && lua5.1 "${t}_test.lua" > /tmp/reck_$t.out 2>&1); then
		tail -1 /tmp/reck_$t.out
	else
		cat /tmp/reck_$t.out
		status=1
	fi
	echo
done
exit $status
