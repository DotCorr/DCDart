#!/usr/bin/env bash
# core/tests/conformance/loopheap/run.sh
#
# Conformance target for HEAP-TYPED LOCALS DECLARED IN A LOOP BODY: the
# per-iteration ARC release policy.
#
# This target replaces a compile-time REFUSAL, so it has to assert the
# guarantee that refusal was protecting rather than just that the program now
# builds. The refusal ("naive ARC has no release policy for a loop back edge
# yet") was correct for ADR-0016/0017's policy: tracked locals were released
# only before a `return`, a back edge is not a `return`, so a heap local
# declared in a loop body leaked one object per iteration -- against the
# fixed 64-slot arena of the day (ADR-0015, superseded by ADR-0058) that was
# a SIGTRAP at iteration 65.
#
# So both halves are asserted, and neither alone is sufficient:
#
#   RUNTIME   1000 iterations each allocating one object, on every path out
#             of a loop body (fall-through, `continue`, `break`, `return`,
#             nested, and escaping into a loop-carried variable).
#             `dc_heap_live` -- the allocator's live-object count
#             (ADR-0058) -- is checked back at its baseline after every
#             call. That is an EXACT leak assertion at any heap size, and it
#             also catches a DOUBLE free (that decrements twice and drives
#             the count below baseline, where it wraps). Every computed
#             value is checked too -- a release placed one instruction too
#             early is a use-after-free that keeps `dc_heap_live` perfectly
#             balanced and only shows up in the arithmetic.
#
#   ARC       Exact per-function Alloc/Retain/Release at the DC-IR level via
#             `dc-objdump --arc` (CLAUDE.md's elision rule; ADR-0024). An
#             elision regression is invisible at runtime and catastrophic in
#             aggregate, and the specific regression this target exists to
#             catch -- a release silently dropped from ONE path, e.g. the
#             `continue` edge -- shows up here as a count and at runtime only
#             on the iterations that took it.
#
# Usage:
#   bash core/tests/conformance/loopheap/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-loopheap"
SRC="$EXAMPLE_DIR/loopheap.dart"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "LOOPHEAP: FAIL — $1" >&2; exit 1; }
setup_error() { echo "LOOPHEAP: FAIL — $1" >&2; exit 2; }

[[ -f "$SRC" ]] || setup_error "missing $SRC"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing $EXAMPLE_DIR/main.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"
[[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"

if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-loopheap.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/loopheap.o"
BIN="$WORKDIR/loopheap_test"

# ---------------------------------------------------------------------------
# Step 1 — build for the freestanding target. This is also the regression
# check on the refusal itself: before the per-iteration release policy every
# function in loopheap.dart was rejected by dcc-lower, so a build failure
# here means the refusal came back rather than that codegen broke.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    loopheap.dart -o "$OBJ" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --mode bare --target bare-x86_64 loopheap.dart failed (log above)"; }
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"

# ---------------------------------------------------------------------------
# Step 2 — CLAUDE.md rule 1. Runs identically on every host.
# ---------------------------------------------------------------------------
command -v llvm-nm >/dev/null 2>&1 \
  || fail "llvm-nm not found on PATH (required by verify-freestanding.sh), see docs/known-gaps.md GAP-0001"

VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$OBJ" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
if [[ $VERIFY_STATUS -ne 0 ]] || ! grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass for $OBJ"
fi

# ---------------------------------------------------------------------------
# Step 3 — ARC COUNTS, hand-derived per function.
#
# Read `release` as "number of release SITES", one per path out of the body,
# not as a per-iteration count. The runtime property -- releases equal allocs
# on every executed path -- is what Step 5 proves; what these numbers pin is
# that no path lost its release, which is precisely the regression a runtime
# check can only see on the iterations that actually take that path.
#
#   liveChain     Alloc (a `while` body local)                      alloc 1
#                 released on the body's fall-through             release 1
#   forChain      identical, except the release sits before the
#                 update block rather than the back edge          1 / 1
#   withContinue  one Alloc; TWO release sites, because the body
#                 has two exits -- the `continue` edge and the
#                 fall-through. A count of 1 here is the exact
#                 bug ADR-0050 warns about, reached through ARC
#                 instead of through the update clause.           1 / 2
#   withBreak     same shape: the `break` edge and the
#                 fall-through.                                    1 / 2
#   withReturn    the `return` path (released by _lowerReturn's
#                 whole-stack release, not by the loop) and the
#                 fall-through.                                    1 / 2
#   nested        two Allocs, two releases: the inner local on the
#                 inner body's fall-through, the outer local on
#                 the outer body's -- which is the inner loop's
#                 exit block. Peak live is 2 for any n.            2 / 2
#   lastKept      Alloc 1. Retain 1 is the `Node? keep = null`
#                 declaration retaining the null. Retain 2 is the
#                 `keep = node` reassignment's retain of the new
#                 value. Release 4 = the reassignment's release of
#                 the PREVIOUS keep, the per-iteration release of
#                 the node local, plus one at each of the two
#                 returns.                                         2 / 4 (retain 2)
#
#                 CHANGED BY ADR-0063, from `retain 1 / release 3`.
#                 This is an ATTRIBUTED loss of elision, not a
#                 re-pin to whatever the build now reports.
#
#                 Pass 3 used to cancel the `keep = node` retain
#                 against the per-iteration release, because no
#                 release OF THAT VALUE appeared between them. The
#                 reassignment's release of the PREVIOUS keep does
#                 appear between them, and on the last iteration
#                 before the loop exits, the previous keep and the
#                 new one are values whose objects this pass cannot
#                 tell apart. GAP-0054's rule now invalidates the
#                 pending retain there, so the pair survives.
#
#                 It is +1 retain and +1 release STATICALLY, inside
#                 a loop body, and it is the price of the fix on
#                 this target. Nothing else in the file moves --
#                 the six other functions below are byte-identical,
#                 which is what says this is the aliasing rule
#                 firing and not the pass going quiet.
# ---------------------------------------------------------------------------
ARC_OUT="$( cd "$CORE_DIR/dc-objdump" && dart bin/dc_objdump.dart --arc "$SRC" 2>&1 )" \
  || { echo "$ARC_OUT" >&2; fail "dc-objdump --arc failed (output above)"; }
echo "$ARC_OUT"

arc_is() {
  local fn="$1" want="$2" line got
  line="$(grep -E "^[[:space:]]+${fn}: " <<<"$ARC_OUT")"
  [[ -n "$line" ]] || fail "dc-objdump --arc printed no counts for \"$fn\""
  got="${line#*: }"
  [[ "$got" == "$want" ]] || fail "ARC counts for \"$fn\": expected [$want], got [$got]"
}

arc_is 'liveChain'    'alloc=1 retain=0 release=1 makeweak=0 weakload=0 dropweak=0'
arc_is 'forChain'     'alloc=1 retain=0 release=1 makeweak=0 weakload=0 dropweak=0'
arc_is 'withContinue' 'alloc=1 retain=0 release=2 makeweak=0 weakload=0 dropweak=0'
arc_is 'withBreak'    'alloc=1 retain=0 release=2 makeweak=0 weakload=0 dropweak=0'
arc_is 'withReturn'   'alloc=1 retain=0 release=2 makeweak=0 weakload=0 dropweak=0'
arc_is 'nested'       'alloc=2 retain=0 release=2 makeweak=0 weakload=0 dropweak=0'
# CHANGED BY ADR-0066 (rule N) from retain=2: `Node? keep = null` emits a
# `Retain <NullRef>` for the null initializer, and dc_retain(null) is a
# DEFINED no-op (ADR-0049), so the instruction is now deleted outright. The
# remaining retain is STILL the ADR-0063/GAP-0054 pair -- the reassignment's
# release of the previous keep sits between retain and release, the pass
# cannot tell the two objects apart, and the pair correctly survives
# (`--why` reports it releaseLimited). The release count does NOT drop: all
# four releases are of dynamically-loaded values, not of the static null.
arc_is 'lastKept'     'alloc=1 retain=1 release=4 makeweak=0 weakload=0 dropweak=0'

# VACUOUS-PASS GUARD. Every assertion above is an equality against a string,
# so a `dc-objdump` that printed nothing at all would have been caught by the
# per-function "printed no counts" check -- but a `dc-objdump` that printed
# the seven lines and nothing else would not prove the loop bodies were even
# reached. The TOTAL is asserted separately for that reason.
# TOTAL retain follows lastKept's ADR-0066 change (2 -> 1); releases unmoved.
arc_is 'TOTAL' 'alloc=8 retain=1 release=14 makeweak=0 weakload=0 dropweak=0'

echo "  ARC ok: every path out of every loop body carries its own release"

# ---------------------------------------------------------------------------
# Step 4 — link. Shared helper (GAP-0048): freestanding -nostdlib link on
# Linux/x86-64, ordinary hosted link everywhere else. No host gate here, and
# no hand-written `_start`.
# ---------------------------------------------------------------------------
source "$CORE_DIR/tests/conformance/_lib/hosted-link.sh"
dc_link "$BIN" "$EXAMPLE_DIR/main.c" "$OBJ" "$SRC"

# ---------------------------------------------------------------------------
# Step 5 — RUN. See core/examples/m2-loopheap/main.c for what each exit code
# means; the odd codes are "value wrong" (use-after-free / miscompile) and
# the even ones are "dc_heap_live off baseline" (leak or double free).
# ---------------------------------------------------------------------------
"$BIN"
ACTUAL=$?
if [[ $ACTUAL -ne 0 ]]; then
  fail "loopheap_test exited $ACTUAL — see core/examples/m2-loopheap/main.c for what that code means (odd = wrong value, even = live-object count off baseline)"
fi

echo "LOOPHEAP: PASS — dcc build -> verify-freestanding pass -> ARC counts exact -> $DC_LINK_MODE link -> 1000-iteration loops on all of fall-through/continue/break/return/nested/escaping paths, live-object count back at baseline after every call"
exit 0
