#!/usr/bin/env bash
# core/tests/conformance/hashmap-bench/run.sh
#
# CORRECTNESS TARGET FOR M3's `hashmap` PAIR (ADR-0061). Not a timing harness
# -- `bench/run-bench.sh` does the timing and refuses noisy samples. This
# target asserts the properties every one of those timings depends on, none of
# which the timing harness checks:
#
#   1. THE TWO PHASES SHARE ONE MAP IMPLEMENTATION. `verify-parity.sh` diffs
#      the shared-map region of all three file pairs. The pair's entire finding
#      is "same work, different order"; a drift here makes it unfalsifiable.
#
#   2. ALL FIVE IMPLEMENTATIONS AGREE, ACROSS PHASES. run-bench.sh checks that
#      the implementations of ONE benchmark agree; it has no reason to check
#      that phase A agrees with phase B, and that is the claim the pair rests
#      on. Checked here at several round counts, including 1 (where the churn
#      phase's drain loop is the whole delete count) and 3 (where all three
#      size-mix eras are entered).
#
#   3. DCDart LEAKS NOTHING. `dc_heap_live` back at 0 after the kernel, which
#      is leak-freedom at any scale across every size class (ADR-0058). A
#      benchmark that leaked would be timing a heap that only grows.
#
#   4. THE WORKLOAD FITS THE SHIPPING DEFAULT HEAP. `dc_heap_bump` is read per
#      class and printed against the 32,768-block ceiling of the tightest one.
#      The bump cursor never retreats, so its final value IS that class's
#      high-water mark -- which makes this both the fit check and the
#      measurement of what ADR-0058's no-coalescing heap holds.
#      `--heap-region-bytes` is deliberately NOT used anywhere here.
#
#   5. THE @bare OBJECTS LINK FREESTANDING. CLAUDE.md rule 1 applies to
#      benchmark sources like any other `@bare` code.
#
# Usage:  bash core/tests/conformance/hashmap-bench/run.sh
# Exit:   0 PASS, 1 FAIL, 2 harness/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BENCH_DIR="$CORE_DIR/bench"
A_DIR="$BENCH_DIR/benchmarks/hashmap-burst"
B_DIR="$BENCH_DIR/benchmarks/hashmap"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "HASHMAP-BENCH: FAIL — $1" >&2; exit 1; }
setup_error() { echo "HASHMAP-BENCH: FAIL — $1" >&2; exit 2; }

for f in "$A_DIR/bench.dart" "$B_DIR/bench.dart" "$A_DIR/kernel.c" "$B_DIR/kernel.c" \
         "$A_DIR/kernel_trapck.c" "$B_DIR/kernel_trapck.c" \
         "$B_DIR/verify-parity.sh" "$B_DIR/index-tax/kernel_array.c"; do
  [[ -f "$f" ]] || setup_error "missing $f"
done

if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  setup_error "neither dcc nor dart found on PATH"
fi
command -v clang >/dev/null 2>&1 || setup_error "clang not found on PATH"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-hashmapbench.XXXXXX")" || setup_error "no temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# 1 — one map implementation, two phases
# ---------------------------------------------------------------------------
bash "$B_DIR/verify-parity.sh" || fail "the two phases no longer share one map implementation"

# ---------------------------------------------------------------------------
# 5 (first, because it gates the rest) — freestanding, then host builds
# ---------------------------------------------------------------------------
for phase in hashmap hashmap-burst; do
  d="$BENCH_DIR/benchmarks/$phase"
  ( cd "$d" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
      bench.dart -o "$WORKDIR/$phase.bare.o" ) >"$WORKDIR/$phase.bare.log" 2>&1 \
    || { cat "$WORKDIR/$phase.bare.log" >&2; fail "$phase: freestanding build failed"; }
  if command -v llvm-nm >/dev/null 2>&1; then
    OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$WORKDIR/$phase.bare.o" 2>&1)"
    grep -q "FREESTANDING: pass" <<<"$OUT" || { echo "$OUT" >&2; fail "$phase: undefined symbol in a @bare object"; }
    echo "  $phase: FREESTANDING pass"
  else
    setup_error "llvm-nm not found (required by verify-freestanding.sh)"
  fi
  ( cd "$d" && "${DCC_CMD[@]}" build --mode bare --target host \
      bench.dart -o "$WORKDIR/$phase.o" ) >"$WORKDIR/$phase.log" 2>&1 \
    || { cat "$WORKDIR/$phase.log" >&2; fail "$phase: host build failed"; }
done

# ---------------------------------------------------------------------------
# The driver. Reads the checksum, the live count and every class's high-water
# mark out of the SAME process, so nothing has to be correlated across runs.
# ---------------------------------------------------------------------------
cat > "$WORKDIR/probe.c" <<'CEOF'
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
extern uint64_t benchKernel(uint64_t);
#ifdef DCDART_SIDE
extern uint64_t dc_heap_live;
extern uint64_t dc_heap_bump[];
extern const uint64_t dc_heap_sizes[];
#endif
int main(int argc, char **argv) {
    uint64_t n = strtoull(argv[1], 0, 10);
    printf("CHECKSUM %llu\n", (unsigned long long)benchKernel(n));
#ifdef DCDART_SIDE
    printf("LIVE %llu\n", (unsigned long long)dc_heap_live);
    for (int i = 0; i < 16; i++) {
        if (!dc_heap_bump[i]) continue;
        printf("CLASS %llu %llu\n", (unsigned long long)dc_heap_sizes[i],
               (unsigned long long)(dc_heap_bump[i] / dc_heap_sizes[i]));
    }
#endif
    return 0;
}
CEOF

TRIPLE="$(clang -dumpmachine)"
CFLAGS=(--target="$TRIPLE" -O2 -ffreestanding -fno-builtin -fno-stack-protector
        -fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables -std=c11)

clang -O2 -DDCDART_SIDE -c "$WORKDIR/probe.c" -o "$WORKDIR/probe_dc.o" || setup_error "probe build failed"
clang -O2 -c "$WORKDIR/probe.c" -o "$WORKDIR/probe_c.o" || setup_error "probe build failed"

clang -o "$WORKDIR/dc_a" "$WORKDIR/probe_dc.o" "$WORKDIR/hashmap-burst.o" || setup_error "link failed"
clang -o "$WORKDIR/dc_b" "$WORKDIR/probe_dc.o" "$WORKDIR/hashmap.o" || setup_error "link failed"

cbuild() { # <name> <src> <extra...>
  local name="$1" src="$2"; shift 2
  clang "${CFLAGS[@]}" "$@" -c "$src" -o "$WORKDIR/$name.o" || setup_error "$name: C build failed"
  clang -o "$WORKDIR/$name" "$WORKDIR/probe_c.o" "$WORKDIR/$name.o" || setup_error "$name: link failed"
}
cbuild c_a  "$A_DIR/kernel.c"
cbuild c_b  "$B_DIR/kernel.c"
cbuild ck_a "$A_DIR/kernel_trapck.c" -I"$BENCH_DIR/harness"
cbuild ck_b "$B_DIR/kernel_trapck.c" -I"$BENCH_DIR/harness"
cbuild ar_a "$B_DIR/index-tax/kernel_array.c" -DPHASE_A
cbuild ar_b "$B_DIR/index-tax/kernel_array.c" -DPHASE_B

# ---------------------------------------------------------------------------
# 2, 3, 4 — checksums, leak-freedom, heap fit
# ---------------------------------------------------------------------------
ck() { "$WORKDIR/$1" "$2" | awk '/^CHECKSUM /{print $2}'; }

for n in 1 2 3 7; do
  ref="$(ck dc_b "$n")"
  [[ -n "$ref" ]] || fail "rounds=$n: DCDart/churn produced no checksum"
  for impl in dc_a c_a c_b ck_a ck_b ar_a ar_b; do
    got="$(ck "$impl" "$n")"
    [[ "$got" == "$ref" ]] || fail "rounds=$n: $impl returned $got, DCDart/churn returned $ref.
  The two phases, the two C baselines and the array-indexed control must all
  compute the same value. They do not, so no timing of them is comparable."
  done
  echo "  rounds=$n: all 8 implementations agree (checksum $ref)"
done

for side in dc_a dc_b; do
  live="$("$WORKDIR/$side" 3 | awk '/^LIVE /{print $2}')"
  [[ "$live" == "0" ]] || fail "$side: dc_heap_live is $live after the kernel, expected 0 (leak)"
done
echo "  dc_heap_live back at 0 after both phases"

# Heap fit, at the real BENCH_ARG.
ARG="$(awk -F= '/^BENCH_ARG=/{print $2}' "$B_DIR/manifest.sh")"
[[ -n "$ARG" ]] || setup_error "could not read BENCH_ARG from $B_DIR/manifest.sh"
echo "  per-class high-water at BENCH_ARG=$ARG (bump cursors never retreat):"
worst=0
for side in dc_a dc_b; do
  while read -r _ cls blocks; do
    ceiling=$(( (2 * 1024 * 1024) / cls ))
    pct=$(awk -v b="$blocks" -v c="$ceiling" 'BEGIN{printf "%.2f", 100*b/c}')
    over=$(awk -v b="$blocks" -v c="$ceiling" 'BEGIN{print (b>=c) ? 1 : 0}')
    [[ "$over" == "0" ]] || fail "$side: size class $cls is FULL ($blocks of $ceiling).
  This is the ceiling, not a benchmark bug -- it surfaces as a bare SIGTRAP with
  no message. Size the workload down; do NOT raise --heap-region-bytes, because
  a gate number must describe the configuration DCDart ships."
    printf "    %-6s class %5s: %6s / %6s blocks (%s%%)\n" "$side" "$cls" "$blocks" "$ceiling" "$pct"
  done < <("$WORKDIR/$side" "$ARG" | grep '^CLASS ')
done

# ---------------------------------------------------------------------------
# 6. EXACT ARC COUNTS on the churn phase (CLAUDE.md: anything touching ARC
#    codegen needs an elision test with exact counts). Pinned after ADR-0066:
#
#    - THE LOOKUP PATH IS RETAIN-FREE. `tlookup`/`chainSum`/`valueSum` are
#      proven refcount-transparent (rule T: every release covered, recursion
#      included) and their own descent pairs cancel against a frontier of
#      per-path releases (rule F). If any of these reads retain>0, one of the
#      two rules stopped firing on the gate benchmark -- the exact regression
#      GAP-0062 documents as invisible at runtime.
#    - THE MUTATING PATH KEEPS ITS PAIRS. `tinsert` retain=4 / `unlinkFrom`
#      retain=2 are the GAP-0067 refusals: their bodies release old field
#      values (`Store new; Release old`), so rule T must NOT mark them
#      transparent and their descent pairs must survive. If `tinsert` ever
#      reads retain<4 WITHOUT a new safety argument in an ADR, treat it as a
#      miscompilation risk, not an improvement -- this is the direction of
#      failure that produced GAP-0054.
#    - `mapInsert` retain=3: the three value-store retains (opaque over
#      tinsert); its nine null-initializer retains are deleted by rule N
#      (dc_retain(null) is a defined no-op, ADR-0049).
# ---------------------------------------------------------------------------
ARC_OUT="$( cd "$CORE_DIR/dc-objdump" && dart bin/dc_objdump.dart --arc "$B_DIR/bench.dart" 2>&1 )" \
  || { echo "$ARC_OUT" >&2; fail "dc-objdump --arc failed on the churn phase (output above)"; }

arc_is() {
  local fn="$1" want="$2" line got
  line="$(grep -E "^[[:space:]]+${fn}: " <<<"$ARC_OUT")"
  [[ -n "$line" ]] || fail "dc-objdump --arc printed no counts for \"$fn\""
  got="${line#*: }"
  [[ "$got" == "$want" ]] || fail "ARC counts for \"$fn\": expected [$want], got [$got]"
}

arc_is 'tlookup'    'alloc=0 retain=0 release=0 makeweak=0 weakload=0 dropweak=0'
arc_is 'chainSum'   'alloc=0 retain=0 release=0 makeweak=0 weakload=0 dropweak=0'
arc_is 'valueSum'   'alloc=0 retain=0 release=0 makeweak=0 weakload=0 dropweak=0'
arc_is 'buildTrie'  'alloc=2 retain=0 release=0 makeweak=0 weakload=0 dropweak=0'
arc_is 'tinsert'    'alloc=0 retain=4 release=6 makeweak=0 weakload=0 dropweak=0'
arc_is 'unlinkFrom' 'alloc=0 retain=2 release=4 makeweak=0 weakload=0 dropweak=0'
arc_is 'mapInsert'  'alloc=6 retain=3 release=6 makeweak=0 weakload=0 dropweak=0'
echo "  ARC counts pinned: lookup path retain-free, mutating path's GAP-0067 pairs intact"

echo "HASHMAP-BENCH: PASS — one map implementation, 8 implementations agreeing at 4 round counts, no leak, inside the shipping default heap, both @bare objects freestanding, ARC counts pinned"
exit 0
