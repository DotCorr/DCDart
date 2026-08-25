#!/usr/bin/env bash
# core/tests/run-conformance.sh -- run every conformance target.
#
#   bash core/tests/run-conformance.sh
#
# `dcc` and `clang` must be on PATH (and `llvm-nm`, for verify-freestanding.sh).
#
# Exit-status contract, stated by every harness's own header:
#   0 = PASS   1 = FAIL   2 = harness usage/setup error
#
# Exit 2 is reported as SKIP *with its reason line printed*, never swallowed.
# Several harnesses gate themselves to Linux/x86-64 (a freestanding entry stub
# links only there) and exit 2 on a Darwin host; that is a real gap in host
# coverage, not a pass, so skips are counted and listed separately and the
# summary is never called all-green while any exist.
set -uo pipefail
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CORE_DIR" || exit 2
echo "=== host: $(uname -s)/$(uname -m) ==="
pass=0; fail=0; skip=0; failed=""; skipped=""
for d in tests/conformance/*/; do
  n=$(basename "$d")
  # Not every directory here is a target: _lib holds the shared helper and has
  # no run.sh. Globbing it in produced a phantom FAIL, which is the same class
  # of defect as GAP-0048 pointing the other way -- a number that does not mean
  # what the summary line says it means.
  [[ -f "$d/run.sh" ]] || continue
  out=$(bash "$d/run.sh" 2>&1); st=$?
  if [[ $st -eq 0 ]] && grep -qE ": PASS" <<<"$out"; then
    echo "PASS  $n"; pass=$((pass+1))
  elif [[ $st -eq 2 ]]; then
    echo "SKIP  $n — $(grep -oE 'FAIL — .*' <<<"$out" | head -1 | sed 's/^FAIL — //')"
    skip=$((skip+1)); skipped="$skipped $n"
  else
    echo "FAIL  $n"; tail -6 <<<"$out" | sed 's/^/      /'
    fail=$((fail+1)); failed="$failed $n"
  fi
done
# The host and link mode go IN the summary line. GAP-0048 exists because a
# bare "32 passed, 0 failed" was quoted for weeks without anyone knowing it had
# been measured in a Linux container rather than on the dev host.
echo "===== conformance: $pass passed, $fail failed, $skip skipped"' '"[host $(uname -s)/$(uname -m), link mode: $(source tests/conformance/_lib/hosted-link.sh 2>/dev/null; dc_link_mode 2>/dev/null || echo unknown)] ====="
[[ -n "$failed" ]]  && echo "  failed: $failed"
[[ -n "$skipped" ]] && echo "  skipped (host-gated, NOT passes):$skipped"
exit $(( fail > 0 ? 1 : 0 ))
