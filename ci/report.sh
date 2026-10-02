#!/bin/bash
# Turn the important lines of a build/test log into GitHub annotations (readable without downloading logs).
# usage: ci/report.sh <logfile> <title>
log="$1"; title="$2"
[ -f "$log" ] || exit 0
emit() {
  local s="$1"
  s="${s//'%'/'%25'}"; s="${s//$'\r'/}"; s="${s//$'\n'/'%0A'}"
  echo "::$2 title=$title::$s"
}
summary=$(grep -E "Executed [0-9]+ tests?|Test Suite 'All tests'|Build complete|BUILD (SUCCEEDED|FAILED)|ARCHIVE (SUCCEEDED|FAILED)|EXPORT (SUCCEEDED|FAILED)|Upload succeeded|tests? passed|tests? failed" "$log" | tail -4)
errors=$(grep -E "error:|: error|failed \(|XCTAssert|Fatal|fatal error|Test Case .* failed|issue at|✘|Uploaded|ERROR|No profiles|requires a provisioning|Signing" "$log" | grep -v "^warning" | awk '!seen[$0]++' | head -45)
[ -n "$summary" ] && emit "$summary" notice
[ -n "$errors" ] && emit "$errors" warning
exit 0
