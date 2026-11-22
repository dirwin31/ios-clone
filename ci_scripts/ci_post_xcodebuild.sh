#!/bin/sh
set -eu
# Simulator tests provide extra search paths. Verify the executable that ships.
[ -n "${CI_ARCHIVE_PATH:-}" ] || exit 0
[ "${CI_XCODEBUILD_EXIT_CODE:-0}" = 0 ] || exit 0

app="$CI_ARCHIVE_PATH/Products/Applications/GalaxyBluetooth.app"
executable="$app/GalaxyBluetooth"
otool -l "$executable" | awk '
    $1 == "cmd" { rpath = ($2 == "LC_RPATH") }
    rpath && $1 == "path" && $2 == "@executable_path/Frameworks" { found = 1 }
    END { if (!found) { print "App cannot load its embedded frameworks" > "/dev/stderr"; exit 1 } }
'
otool -L "$executable" | awk '$1 ~ /^@rpath\/.*\.framework\// { sub(/^@rpath\//, "", $1); print $1 }' |
while IFS= read -r library; do
    test -f "$app/Frameworks/$library" || { echo "Missing embedded library: $library" >&2; exit 1; }
done
