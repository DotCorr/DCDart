#!/usr/bin/env bash
# core/tests/conformance/elide-alias/run.sh
#
# Conformance target for GAP-0054 / ADR-0063: elision pass 3 must not
# delete a retain/release pair across a SURVIVING `Release` of a value
# that may ALIAS the retained object.
#
# This is a MISCOMPILATION regression target, and it is worth saying what
# that means for how it is written. Before ADR-0063, `dcc build` at -O2
# turned `examples/m3-elide-alias/elide_alias.dart`'s `aliasBug` into a
# program that returned 198 where 110 is correct -- a read of freed memory
# whose slot had already been handed back out. It did that while
# `dc_heap_live` read zero on every call and every refcount balanced,
# because cancelling a retain/release pair frees the object exactly once;
# it just frees it far too early. NO LEAK TEST IN THIS REPO COULD SEE IT.
#
# So three things are asserted, and the third is the one that would have
# caught it:
#
#   1. FREESTANDING -- CLAUDE.md rule 1, over the bare-x86_64 object.
#   2. ARC COUNTS   -- exact per-function counts from `dc-objdump --arc`,
#      in BOTH directions. The pairs that must now survive, and -- just as
#      load-bearing -- the pair that must still be ELIDED, so that a
#      "fix" which quietly turned pass 3 into a no-op fails here rather
#      than passing everything and costing performance everywhere.
#   3. BEHAVIOUR    -- the values. 110, not 198.
#
# The link step goes through tests/conformance/_lib/hosted-link.sh, so this
# harness has NO Linux/x86-64 gate (GAP-0048).
#
# Usage:
#   bash core/tests/conformance/elide-alias/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m3-elide-alias"
SRC="$EXAMPLE_DIR/elide_alias.dart"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "ELIDE-ALIAS: FAIL — $1" >&2; exit 1; }
setup_error() { echo "ELIDE-ALIAS: FAIL — $1" >&2; exit 2; }

[[ -f "$SRC" ]] || setup_error "missing $SRC"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing $EXAMPLE_DIR/main.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"
[[ -f "$ALLOWLIST" ]] || setup_error "missing $ALLOWLIST"

if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi
command -v clang >/dev/null 2>&1 || fail "clang not found on PATH"
command -v llvm-nm >/dev/null 2>&1 || fail "llvm-nm not found on PATH (required by verify-freestanding.sh)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-elide-alias.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

source "$CORE_DIR/tests/conformance/_lib/hosted-link.sh"

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    elide_alias.dart -o "$WORKDIR/elide_alias.o" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed"; }

VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$WORKDIR/elide_alias.o" 2>&1)"
echo "$VERIFY_OUT"
grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT" \
  || fail "elide-alias introduced an undefined symbol — CLAUDE.md rule 1"

# ---------------------------------------------------------------------------
# Step 2 — ARC COUNTS, in both directions.
# ---------------------------------------------------------------------------
ARC_OUT="$( cd "$CORE_DIR/dc-objdump" && dart bin/dc_objdump.dart --arc "$SRC" 2>&1 )" \
  || { echo "$ARC_OUT" >&2; fail "dc-objdump --arc failed"; }
echo "$ARC_OUT"

arc_is() {
  local fn="$1" want="$2"
  local line
  line="$(grep -E "^[[:space:]]+${fn}: " <<<"$ARC_OUT")"
  [[ -n "$line" ]] || fail "dc-objdump --arc printed no counts for \"$fn\""
  local got="${line#*: }"
  [[ "$got" == "$want" ]] || fail "ARC counts for \"$fn\": expected [$want], got [$got]"
}

# --- The pairs that MUST SURVIVE. -----------------------------------------
#
# aliasBug. Derivation, since this is the number the bug moved:
#
#   Node(v)              Alloc                                    alloc 1
#   Cell(n)              Alloc                                    alloc 2
#   n = Node(u64(0))     Alloc + release of the old local         alloc 3
#   final got = c.next   Retain got  (ADR-0017 alias retain)      RETAIN 1
#   c.next = Node(...)   Alloc + release of the old FIELD value   alloc 4
#   Node(u64(198))       Alloc                                    alloc 5
#   <exit>               release got, c, n, other
#
# `Retain got` and its release straddle the release of the old field
# value, which is THE SAME OBJECT under a different DCValue. retain=1 is
# the assertion: before ADR-0063 this read retain=0, and that zero was the
# use-after-free.
arc_is 'aliasBug' 'alloc=5 retain=1 release=5 makeweak=0 weakload=0 dropweak=0'

# releaseThroughDestructor. COUNT RE-PINNED retain=1 -> retain=0 by
# ADR-0068's run-atomic release matching, and the justification is owed in
# full because the previous pin was a deliberate ADR-0063 refusal:
#
#   The pair straddles `Release c`, and `Cell_dtor` releases `c.next` --
#   the release that can free the aliased object is not even syntactically
#   a release of a Node. ADR-0063 refused it because "no use follows the
#   aliasing release" was a fact about dcc-lower's emission order, asserted
#   in no file the pass could read. ADR-0068 cancels it because that fact
#   is now checked LOCALLY: all three releases are literally ADJACENT in
#   the block body (`Release n; Release c; Release got`, nothing between),
#   adjacent releases are pure decrements that commute, and the last use
#   (`got.n`) sits before the run -- inside the run no instruction can
#   touch a freed object because the run contains only releases. GAP-0054's
#   original entry said this exact instance was safe and named this exact
#   reason; what changed is that the pass now PROVES it instead of assuming
#   it.
#
#   The dangerous version of the shape -- ANY use between the aliasing
#   release and the pair's release -- still refuses: aliasBug and
#   aliasBugNullable above (retain=1, the actual 198-vs-110 miscompilation
#   shapes) are the assertion of that, together with dc-elide's own
#   "use between the releases" negative unit test.
arc_is 'releaseThroughDestructor' 'alloc=2 retain=0 release=1 makeweak=0 weakload=0 dropweak=0'

# --- The pair that MUST STILL BE ELIDED. ----------------------------------
#
# THIS LINE IS THE ANTI-NO-OP GUARD. A local alias whose retain reaches its
# own release with no release of anything in between is exactly what pass 3
# exists to remove, and it is untouched by ADR-0063. If this ever reads
# retain=1, the fix has been widened into "disable elision", which would
# pass every correctness check in the suite while costing real performance
# on every benchmark.
arc_is 'stillElided' 'alloc=1 retain=0 release=1 makeweak=0 weakload=0 dropweak=0'

# --- The nullable variant, unchanged by ADR-0063. --------------------------
#
# Asserted so that the reason stays visible: a nullable field needs a null
# test to dereference, the test is a CondBranch, and pass 3 is single-block
# -- so the retain and its release were never in the same block and were
# never candidates. It was never nullability that made this safe.
arc_is 'aliasBugNullable' 'alloc=5 retain=1 release=9 makeweak=0 weakload=0 dropweak=0'

# retain 3 -> 2, release 19 -> 18: releaseThroughDestructor's pair now
# cancels (ADR-0068, justified at its own assertion above); aliasBug and
# aliasBugNullable are byte-for-byte unchanged.
arc_is 'TOTAL' 'alloc=13 retain=2 release=18 makeweak=0 weakload=0 dropweak=0'
echo "  ARC counts ok: the aliasing pairs survive, and stillElided is still elided"

# ---------------------------------------------------------------------------
# Step 3 — BEHAVIOUR. The half that would actually have caught this.
# ---------------------------------------------------------------------------
BIN="$WORKDIR/elide_alias_bin"
dc_link "$BIN" "$EXAMPLE_DIR/main.c" "$WORKDIR/elide_alias.o" "$SRC"
echo "  link mode: $DC_LINK_MODE"

RUN_OUT="$("$BIN" 2>&1)"; RUN_RC=$?
[[ -n "$RUN_OUT" ]] && echo "$RUN_OUT"
case "$RUN_RC" in
  0) ;;
  1) fail "dc_heap_live was not zero before any call — the heap did not start at baseline" ;;
  2|4|6|8|10|11)
     fail "wrong VALUE returned (see the line above). 198 means pass 3 elided a retain/release pair across an aliasing Release — GAP-0054 has regressed" ;;
  3|5|7|9|12)
     fail "dc_heap_live drifted off zero — the pair is now unbalanced (over- or under-retained)" ;;
  *) fail "harness binary exited $RUN_RC (unexpected; a signal here would mean a crash, not a wrong value)" ;;
esac

echo "ELIDE-ALIAS: PASS"
