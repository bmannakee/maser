#!/bin/sh
# Usage: runhook.sh script.swift — builds Maser with the hook running that script, runs it, prints its output.
S=/private/tmp/claude-501/-Users-brianmannakee-dev-maser/0f5c88ee-dc26-40ae-a24d-e9285809df29/scratchpad
cd /Users/brianmannakee/dev/maser
uv run --no-project python $S/hook.py add "$1" || exit 1
scripts/bundle 2>&1 | grep -E "error" ; uv run --no-project python $S/hook.py remove
out=$S/hook-out.txt; rm -f $out
pkill -f MacOS/Maser; sleep 1
open -n -W --env MASER_REPRO=1 --stderr $out --stdout $out .build/Maser.app --args https://github.com/bmannakee/maser/pull/15 &
for i in $(seq 1 60); do sleep 1; grep -q survived $out 2>/dev/null && break; done
sleep 1
grep -vE "^\s*$" $out | grep -vE "^[0-9]{4}-" | tail -20
