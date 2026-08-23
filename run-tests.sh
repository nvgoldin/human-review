#!/usr/bin/env bash
# Run the black-box CLI suite.
#
# The suite is written with swift-testing (`import Testing`). On a Mac with
# Xcode installed, plain `swift test` runs it. On a Mac with only the Command
# Line Tools there is no XCTest.framework at all, and SwiftPM does not put the
# Command Line Tools framework directory on the search path, so three extra
# flags are needed. This script picks the right invocation either way.
#
# It also refuses to report success on a run that executed no tests. Putting
# `-F` into Package.swift instead of here would make SwiftPM's synthesized
# runner compile away to nothing: the build goes green, zero tests run, and
# nothing says so.

set -euo pipefail

cd "$(dirname "$0")"

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
DEVELOPER_DIR_IN_USE="$(xcode-select -p 2>/dev/null || echo "")"

echo "→ Building..."
swift build

TEST_ARGS=()
if [[ "$DEVELOPER_DIR_IN_USE" == *CommandLineTools* ]]; then
  if [[ ! -d "$CLT_FRAMEWORKS/Testing.framework" ]]; then
    echo "✗ No Xcode and no $CLT_FRAMEWORKS/Testing.framework — nothing can run the suite."
    echo "  Install Xcode, or update the Command Line Tools."
    exit 1
  fi
  echo "→ Command Line Tools toolchain — adding swift-testing framework flags."
  TEST_ARGS=(
    -Xswiftc -F -Xswiftc "$CLT_FRAMEWORKS"
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
    -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS"
  )
fi

LOG="$(mktemp -t human-review-tests)"
trap 'rm -f "$LOG"' EXIT

set +e
swift test "${TEST_ARGS[@]}" 2>&1 | tee "$LOG"
STATUS="${PIPESTATUS[0]}"
set -e

TEST_COUNT="$(sed -n 's/.*Test run with \([0-9][0-9]*\) tests.*/\1/p' "$LOG" | tail -1)"
TEST_COUNT="${TEST_COUNT:-0}"

if [[ "$STATUS" -ne 0 ]]; then
  echo "✗ Suite failed."
  exit "$STATUS"
fi
if [[ "$TEST_COUNT" -lt 1 ]]; then
  echo "✗ The run reported success but executed 0 tests. Treat that as a failure —"
  echo "  the test target almost certainly failed to link against Testing.framework."
  exit 1
fi

echo "✓ $TEST_COUNT tests passed."
