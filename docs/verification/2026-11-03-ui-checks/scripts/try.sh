#!/bin/sh
# Usage: try.sh VAR — runs the bundled repro with MASER_REPRO and VAR set; prints how far it got.
cd /Users/brianmannakee/dev/maser
out=/private/tmp/claude-501/-Users-brianmannakee-dev-maser/0f5c88ee-dc26-40ae-a24d-e9285809df29/scratchpad/try-$1.txt
rm -f "$out"
open -n -W --env MASER_REPRO=1 --env "$1=1" --stderr "$out" --stdout "$out" .build/Maser.app --args https://github.com/bmannakee/maser/pull/15 &
for i in $(seq 1 40); do sleep 1; grep -q survived "$out" 2>/dev/null && break; done
sleep 1
echo "$1: $(grep -c '^tab' "$out") tab switches, $(grep -c survived "$out") survived"
pkill -f MacOS/Maser 2>/dev/null
