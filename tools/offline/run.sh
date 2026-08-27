#!/bin/sh
# Runs every offline check. Needs a real Lua 5.1 interpreter -- the game's own version -- so that
# anything these accept is something the client will accept too:
#
#   apt-get install lua5.1     (or: brew install lua@5.1)
#
# Usage: sh tools/offline/run.sh        (from anywhere; BASIL_ROOT overrides the repo path)
set -e
here=$(cd "$(dirname "$0")" && pwd)
BASIL_ROOT=${BASIL_ROOT:-$(cd "$here/../.." && pwd)}
export BASIL_ROOT

echo "== luac -p =="
# -exec, not `for f in $(find ...)`: the live plugin path contains spaces ("The Lord of the Rings
# Online"), and word-splitting the find output silently checked nothing and reported a bogus
# "cannot open .../The" error. Only the no-space symlinked path used to work.
find "$BASIL_ROOT" -name '*.lua' -not -path '*/.git/*' -not -path '*/tools/*' \
	-exec luac5.1 -p {} + || exit 1
echo "  all files parse under Lua 5.1"
echo

status=0
for t in slice graph buffs lifecycle chatpost analysis windows options load; do
	echo "== $t =="
	if (cd "$here" && lua5.1 "${t}_test.lua" > /tmp/basil_$t.out 2>&1); then
		tail -1 /tmp/basil_$t.out
	else
		cat /tmp/basil_$t.out
		status=1
	fi
	echo
done
exit $status
