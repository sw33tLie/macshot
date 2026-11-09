#!/bin/bash
# Run headless tests. Failures retain the full log and xcresult for inspection.
# Usage: scripts/run-tests.sh [--offline] [ClassName[/testName] ...]
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

test_directory=$(mktemp -d "${TMPDIR:-/tmp}/macshot-tests.XXXXXX") || exit 1
test_result="$test_directory/results.xcresult"
test_log="$test_directory/xcodebuild.log"
test_args=(
  -scheme macshotTests
  -configuration "${CONFIGURATION:-Debug}"
  -destination 'platform=macOS'
  -resultBundlePath "$test_result"
  # Tests temporarily change preferences in the same xctest domain.
  -parallel-testing-enabled NO
  CODE_SIGNING_ALLOWED=NO
)
for test_filter in "$@"; do
  if [[ "$test_filter" == --offline ]]; then
    test_args+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) OFFLINE')
  else
    test_args+=(-only-testing:"macshotTests/$test_filter")
  fi
done

xcodebuild "${test_args[@]}" test > "$test_log" 2>&1
test_build_status=$?

xcrun xcresulttool get test-results summary --path "$test_result" --format json 2>/dev/null \
  | python3 -c '
import json, sys
try:
    result = json.load(sys.stdin)
except Exception:
    print("Could not read the test result bundle.", file=sys.stderr)
    sys.exit(1)
passed = result.get("passedTests", 0)
failed = result.get("failedTests", 0)
skipped = result.get("skippedTests", 0)
print("=== %s: %d passed, %d failed, %d skipped ===" % (
    result.get("result", "Unknown"), passed, failed, skipped))
for failure in result.get("testFailures", []):
    print("\nFAIL %s.%s" % (failure.get("targetName", ""), failure.get("testName", "")))
    for line in (failure.get("failureText") or "").strip().splitlines():
        print("     " + line)
if passed + failed == 0:
    print("No tests ran; check the selected test filter.", file=sys.stderr)
    sys.exit(1)
sys.exit(1 if failed or result.get("testFailures") else 0)
'
test_summary_status=$?

if (( test_build_status != 0 || test_summary_status != 0 )); then
  # Include non-Swift failures too: signing, dependency resolution, linker,
  # test discovery and runner crashes all need an actionable diagnostic.
  tail -n 60 "$test_log"
  echo "Full log: $test_log"
  echo "Result bundle: $test_result"
  if (( test_build_status != 0 )); then exit "$test_build_status"; fi
  exit 1
fi

if [[ "${MACSHOT_KEEP_TEST_RESULTS:-0}" == 1 ]]; then
  echo "Test artifacts: $test_directory"
else
  rm -rf "$test_directory"
fi
