#!/usr/bin/env bash
# core/bench/benchmarks/hashmap/index-tax/run.sh
#
# Measures THE INDEX TAX: what `hashmap`'s C baseline pays for walking a
# depth-10 binary trie instead of indexing a bucket array.
#
# `hashmap` uses a trie on both sides because DCDart cannot express an array
# of ARC-managed references (GAP-0061), and giving C the array while DCDart
# walked the trie would have measured that gap rather than ARC. That choice is
# defensible only if its cost is published, so this script publishes it.
#
# It is NOT a benchmark: no manifest.sh, so run-bench.sh never discovers it,
# and no number it prints can reach a geometric mean. It uses the same timing
# driver and the same flag list as the harness, and it checks that the array
# variant computes the SAME checksum -- an index that computed something else
# would make the ratio meaningless.
#
# Usage:  bash core/bench/benchmarks/hashmap/index-tax/run.sh [rounds] [runs]
set -uo pipefail

ROUNDS="${1:-600}"
RUNS="${2:-9}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCH_DIR="$(cd "$HERE/../.." && pwd)"          # benchmarks/
HARNESS="$(cd "$BENCH_DIR/../harness" && pwd)"

command -v clang >/dev/null || { echo "index-tax: clang not found" >&2; exit 2; }

TRIPLE="$(clang -dumpmachine)"
FLAGS=(--target="$TRIPLE" -O2 -ffreestanding -fno-builtin -fno-stack-protector
       -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables -std=c11)

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-indextax.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

clang -O2 -c "$HARNESS/bench_main.c" -o "$WORK/driver.o" || exit 2

build() { # <out> <src> <extra...>
  local out="$1" src="$2"; shift 2
  clang "${FLAGS[@]}" "$@" -c "$src" -o "$WORK/$out.o" || exit 2
  clang -o "$WORK/$out" "$WORK/driver.o" "$WORK/$out.o" || exit 2
}

build trie_a  "$BENCH_DIR/hashmap-burst/kernel.c"
build trie_b  "$BENCH_DIR/hashmap/kernel.c"
build array_a "$HERE/kernel_array.c" -DPHASE_A
build array_b "$HERE/kernel_array.c" -DPHASE_B

median() { # <bin>
  "$WORK/$1" "$ROUNDS" "$RUNS" | awk '/^SAMPLE_NS/{a[n++]=$2}
    END{ for(i=0;i<n;i++) for(j=i+1;j<n;j++) if(a[j]<a[i]){t=a[i];a[i]=a[j];a[j]=t}
         printf "%.3f", a[int(n/2)]/1e6 }'
}
checksum() { "$WORK/$1" "$ROUNDS" 1 | awk '/^CHECKSUM/{print $2}'; }

ck_ta="$(checksum trie_a)";  ck_tb="$(checksum trie_b)"
ck_aa="$(checksum array_a)"; ck_ab="$(checksum array_b)"
echo "checksums  trie/A=$ck_ta  trie/B=$ck_tb  array/A=$ck_aa  array/B=$ck_ab"
if [ "$ck_ta" != "$ck_tb" ] || [ "$ck_ta" != "$ck_aa" ] || [ "$ck_ta" != "$ck_ab" ]; then
  echo "index-tax: FAIL — the four C variants do not compute the same value" >&2
  exit 1
fi

ta="$(median trie_a)";  aa="$(median array_a)"
tb="$(median trie_b)";  ab="$(median array_b)"

printf '\n%-8s %12s %12s %10s\n' phase "trie (ms)" "array (ms)" "tax"
awk -v p=A -v t="$ta" -v a="$aa" 'BEGIN{printf "%-8s %12s %12s %9.3fx\n", p, t, a, t/a}'
awk -v p=B -v t="$tb" -v a="$ab" 'BEGIN{printf "%-8s %12s %12s %9.3fx\n", p, t, a, t/a}'
cat <<'NOTE'

  tax = trie / array, both in C, same workload, same checksum. It is the
  share of `hashmap`'s C BASELINE that is the GAP-0061 workaround rather
  than the hash map. The DCDart side pays MORE than this, because each of
  the ten descent levels is a heap-field read into a local -- an alias
  retain (ADR-0017) plus a matching release that ADR-0025's intra-block
  pass 3 cannot elide -- which a bucket array would not need at all.
NOTE
