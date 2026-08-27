#!/usr/bin/env bash
# core/bench/elision-delta.sh — how much does ADR-0025's pass 3 actually remove?
#
#   bash core/bench/elision-delta.sh [file.dart ...]
#
# With no arguments it reports every benchmark and every example that
# allocates.
#
# WHY THIS EXISTS. `elideRedundantRetainReleasePairs` runs inside
# `lowerToDCModule`, so `dc-objdump --arc` reported only what SURVIVED it. The
# pass's unit tests prove THE PASS FIRES. Nothing proved HOW MUCH IT REMOVES
# ON A REAL PROGRAM, and only the second question decides whether an ARC
# benchmark is measuring ARC or measuring a missing optimisation (GAP-0062).
#
# Measured on 2026-08-26, before any fix:
#
#     tree-traversal    6 retains ->  4    removed 2  (33%)
#     json             19 retains -> 18    removed 1  ( 5%)
#     string-pass       0 retains ->  0    nothing to remove
#
# The cause is structural: pass 3 is intra-block and every nullable heap field
# read ends its block at the null test, so on linked structures the pass is
# looking at a program chopped into pieces smaller than the pairs it is trying
# to match.
#
# THIS IS THE ACCEPTANCE CRITERION for the null-test extension. A fix that
# works moves `json`'s survivors substantially below 18. A fix that moves
# nothing means the hypothesis was wrong, which is worth knowing before
# general cross-block dataflow gets built on top of it.
#
# 2026-08-27, ADR-0066 (transparent callees + frontier pairs + null ARC ops):
#
#     hashmap          35 retains -> 13    (lookup path fully retain-free)
#     json             19 retains ->  4
#     tree-traversal    6 retains ->  0
#     whole tree      133 retains -> 42
#
# What survives is attributed in GAP-0066 (releaseLimited) and GAP-0067
# (mutating callees, loops) -- not unmeasured.
#
# It is NOT sufficient on its own. Seeing the pairs and removing them is one
# thing; that removal paying for itself is another. Pair this with
# `closure-heavy`'s ratio, which is the allocator-honest benchmark closest to
# the bar and almost entirely `cur = cur.next` alias traffic.

set -uo pipefail
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CORE_DIR" || exit 2

command -v dart >/dev/null 2>&1 || { echo "elision-delta: no dart on PATH" >&2; exit 2; }

targets=()
if [ "$#" -gt 0 ]; then
  targets=("$@")
else
  for f in bench/benchmarks/*/bench.dart examples/*/*.dart; do
    [ -f "$f" ] || continue
    targets+=("$f")
  done
fi

total_pre=0
total_post=0
printf "%-34s %8s %8s %8s   %s\n" "source" "pre" "post" "removed" "share"
printf "%-34s %8s %8s %8s   %s\n" "----------------------------------" "--------" "--------" "--------" "-----"

for f in "${targets[@]}"; do
  pre_line="$(dart dc-objdump/bin/dc_objdump.dart --arc --no-elide "$f" 2>/dev/null | grep '^  TOTAL:')"
  post_line="$(dart dc-objdump/bin/dc_objdump.dart --arc "$f" 2>/dev/null | grep '^  TOTAL:')"
  # A file that does not lower (an example needing a sibling .c, say) is
  # SKIPPED LOUDLY rather than counted as zero -- a silent zero would look
  # like a program with no ARC traffic, which is a real and different thing.
  if [ -z "$pre_line" ] || [ -z "$post_line" ]; then
    printf "%-34s %8s %8s %8s   (did not lower)\n" "$(basename "$(dirname "$f")")/$(basename "$f")" "-" "-" "-"
    continue
  fi
  pre="$(echo "$pre_line" | sed -n 's/.*retain=\([0-9]*\).*/\1/p')"
  post="$(echo "$post_line" | sed -n 's/.*retain=\([0-9]*\).*/\1/p')"
  [ -n "$pre" ] || pre=0
  [ -n "$post" ] || post=0
  removed=$((pre - post))
  if [ "$pre" -gt 0 ]; then
    share="$(awk -v r="$removed" -v p="$pre" 'BEGIN{printf "%.0f%%", 100*r/p}')"
  else
    share="n/a"
  fi
  printf "%-34s %8s %8s %8s   %s\n" \
    "$(basename "$(dirname "$f")")/$(basename "$f")" "$pre" "$post" "$removed" "$share"
  total_pre=$((total_pre + pre))
  total_post=$((total_post + post))
done

echo
total_removed=$((total_pre - total_post))
if [ "$total_pre" -gt 0 ]; then
  echo "TOTAL retains: $total_pre lowered, $total_post survive, $total_removed removed ($(awk -v r="$total_removed" -v p="$total_pre" 'BEGIN{printf "%.1f%%", 100*r/p}'))"
else
  echo "TOTAL retains: 0 lowered — nothing measured. Check the target list rather than concluding elision is perfect."
fi
