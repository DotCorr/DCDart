#!/usr/bin/env bash
# core/bench/benchmarks/hashmap/verify-parity.sh
#
# `hashmap` (phase B, churn) and `hashmap-burst` (phase A) exist to be
# compared WITH EACH OTHER. The whole design rests on one claim:
#
#     the two phases perform identical logical work and differ only in the
#     ORDER the operations occur in
#
# If that claim stops holding, "B is slower than A" acquires a second possible
# explanation and the finding becomes unfalsifiable. The claim is not left to
# discipline: the map implementation is ONE text, emitted into both
# directories, and this script diffs the region between the shared-map markers
# in all four source files.
#
# The duplication exists because `dcc` compiles ONE library per object file and
# `@bare` functions in imported libraries are silently dropped (GAP-0028), so
# the two benchmarks cannot import a common library.
#
# Usage:  bash core/bench/benchmarks/hashmap/verify-parity.sh
# Exit:   0 identical, 1 drifted, 2 setup error.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
B_DIR="$HERE"
A_DIR="$(cd "$HERE/.." && pwd)/hashmap-burst"

fail() { echo "HASHMAP-PARITY: FAIL — $1" >&2; exit 1; }
setup() { echo "HASHMAP-PARITY: FAIL — $1" >&2; exit 2; }

extract() { # <file> <begin-marker> <end-marker>
  awk -v b="$2" -v e="$3" '
    index($0, b) { on = 1; next }
    index($0, e) { on = 0 }
    on { print }
  ' "$1"
}

for f in "$B_DIR/bench.dart" "$A_DIR/bench.dart" \
         "$B_DIR/kernel.c" "$A_DIR/kernel.c" \
         "$B_DIR/kernel_trapck.c" "$A_DIR/kernel_trapck.c"; do
  [[ -f "$f" ]] || setup "missing $f"
done

check() { # <label> <fileA> <fileB> <begin> <end>
  local label="$1" fa="$2" fb="$3" beg="$4" end="$5"
  local ta tb
  ta="$(extract "$fa" "$beg" "$end")"
  tb="$(extract "$fb" "$beg" "$end")"
  [[ -n "$ta" ]] || setup "no shared-map region found in $fa (marker: $beg)"
  [[ -n "$tb" ]] || setup "no shared-map region found in $fb (marker: $beg)"
  if [[ "$ta" != "$tb" ]]; then
    diff <(printf '%s\n' "$ta") <(printf '%s\n' "$tb") | head -40
    fail "$label: the two phases no longer share one map implementation"
  fi
  echo "  $label: identical ($(printf '%s\n' "$ta" | wc -l | tr -d ' ') lines)"
}

echo "HASHMAP-PARITY: comparing phase A (hashmap-burst) and phase B (hashmap)"
check "bench.dart"       "$A_DIR/bench.dart"      "$B_DIR/bench.dart"       "BEGIN-SHARED-MAP" "END-SHARED-MAP"
check "kernel.c"         "$A_DIR/kernel.c"        "$B_DIR/kernel.c"         "BEGIN-SHARED-MAP" "END-SHARED-MAP"
check "kernel_trapck.c"  "$A_DIR/kernel_trapck.c" "$B_DIR/kernel_trapck.c"  "BEGIN-SHARED-MAP" "END-SHARED-MAP"

# The operation counts are the other half of the claim, and they are a
# property of the two kernels rather than of the shared region. Asserted by
# construction in the source and by the checksum at run time: run-bench.sh
# refuses a ratio when two implementations of ONE benchmark disagree, and
# `run-checksum-parity.sh` (below) additionally requires the two PHASES to
# agree with each other, which run-bench.sh has no reason to check.
echo "HASHMAP-PARITY: PASS — one map implementation, three file pairs"
exit 0
