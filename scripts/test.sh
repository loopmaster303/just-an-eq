#!/bin/bash
# Deterministic test run for a Command Line Tools-only Mac (no Xcode).
# Fails unless Swift Testing reports exactly as many passing tests as there
# are @Test functions; plain `swift test` runs 0 tests and still exits 0.
set -euo pipefail

cd "$(dirname "$0")/.."

clt=/Library/Developer/CommandLineTools
expected=$(grep -rhE '^[[:space:]]*@Test' tests | wc -l | tr -d ' ')
log=$(mktemp "${TMPDIR:-/tmp}/justaneq-test.XXXXXX")
trap 'rm -f "$log"' EXIT

# The testing macro plugin sits in a "testing" subfolder that the build does not
# always add to the plugin search path, so pass it explicitly.
status=0
swift test --disable-sandbox \
    -Xswiftc -F -Xswiftc "$clt/Library/Developer/Frameworks" \
    -Xswiftc -plugin-path -Xswiftc "$clt/usr/lib/swift/host/plugins/testing" \
    >"$log" 2>&1 || status=$?

plain=$(sed $'s/\x1b\\[[0-9;]*m//g' "$log")
summary=$(printf '%s\n' "$plain" | grep -E 'Test run with [0-9]+ tests? .*passed' | tail -1 || true)

if [ "$status" -ne 0 ] || [ -z "$summary" ] || printf '%s\n' "$plain" | grep -qE '✘|error:'; then
    printf '%s\n' "$plain" | tail -30
    echo "FAIL: swift test exit=$status, summary='${summary}'" >&2
    exit 1
fi
reported=$(printf '%s\n' "$summary" | sed -E 's/.*Test run with ([0-9]+) tests?.*/\1/')
if [ "$reported" != "$expected" ]; then
    echo "FAIL: summary reports $reported tests, expected $expected (@Test count)" >&2
    exit 1
fi
echo "$summary"
