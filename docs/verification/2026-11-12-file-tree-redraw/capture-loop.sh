#!/bin/sh
# Captures the window the scenario names in maser-captures/request, as maser-captures/<name>.png, for 4 minutes.
# The folder is in the per-user temporary folder, where the test app writes its requests.
dir="$(getconf DARWIN_USER_TEMP_DIR)maser-captures"
mkdir -p "$dir"
end=$(($(date +%s) + 240))
while [ "$(date +%s)" -lt "$end" ]; do
  if [ -f "$dir/request" ]; then
    set -- $(cat "$dir/request")
    screencapture -x -o -l "$1" "$dir/$2.png"
    rm -f "$dir/request"
  fi
  sleep 0.1
done
