#!/usr/bin/env bash
# core/tests/conformance/generic-class/run.sh
#
# Conformance target for MONOMORPHIZED GENERIC CLASSES
# (docs/decisions/0054-generic-classes.md, closing docs/known-gaps.md
# GAP-0040). Extends ADR-0052, which did generic FUNCTIONS.
#
# Four independent things are asserted, because no one of them catches the
# failures of the others:
#
#   1. FREESTANDING   -- CLAUDE.md rule 1, over the bare-x86_64 object.
#   2. SYMBOL TABLE   -- one specialization per instantiation, no template
#      symbol, and -- the ARC-critical one -- a destructor for Box<Node>
#      and NO destructor for Box<u64> or Box<u32>.
#   3. ARC COUNTS     -- exact Alloc/Retain/Release per function, read from
#      `dc-objdump --arc`. An elision regression is invisible at runtime.
#   4. BEHAVIOUR+LEAK -- values read back at the right width, and the heap
#      back to baseline across all three instantiations.
#
# The link step goes through tests/conformance/_lib/hosted-link.sh, so this
# harness has NO Linux/x86-64 gate (GAP-0048).
#
# Usage:
#   bash core/tests/conformance/generic-class/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m3-generic-class"
SRC="$EXAMPLE_DIR/generic_class.dart"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "GENERIC-CLASS: FAIL — $1" >&2; exit 1; }
setup_error() { echo "GENERIC-CLASS: FAIL — $1" >&2; exit 2; }

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
command -v llvm-nm >/dev/null 2>&1 || fail "llvm-nm not found on PATH (required by verify-freestanding.sh and by the symbol-table assertions, which are the half of this harness that behaviour cannot substitute for)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-generic-class.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

source "$CORE_DIR/tests/conformance/_lib/hosted-link.sh"

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    generic_class.dart -o "$WORKDIR/generic_class.o" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed"; }

VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$WORKDIR/generic_class.o" 2>&1)"
echo "$VERIFY_OUT"
grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT" \
  || fail "generic classes introduced an undefined symbol — CLAUDE.md rule 1"

# ---------------------------------------------------------------------------
# Step 2 — SYMBOL TABLE.
#
# Read from the object rather than inferred from values: a wrong
# implementation that emitted ONE shared Box body would still compute every
# right answer in step 4, and a wrong implementation that emitted a
# destructor for every instantiation would still be leak-free.
# ---------------------------------------------------------------------------
SYMS="$(llvm-nm "$WORKDIR/generic_class.o" 2>/dev/null)"
[[ -n "$SYMS" ]] || fail "llvm-nm produced no symbols; the checks below would pass vacuously"

for want in 'Box\$u64_unwrap' 'Box\$u32_unwrap' 'Box\$Node_unwrap' 'Box\$Node_dtor'; do
  grep -q "$want" <<<"$SYMS" \
    || fail "expected symbol matching \"$want\"; got: $(tr '\n' ' ' <<<"$SYMS")"
done

# The TEMPLATE must not be emitted. A bare `Box_unwrap` would mean something
# lowered `T` as if it had a machine representation and a single layout.
if grep -qE '[[:space:]]_?Box_unwrap$' <<<"$SYMS"; then
  fail "an unspecialized template symbol 'Box_unwrap' was emitted; a generic class has no single layout, so it can have no single method body"
fi
if grep -qE '[[:space:]]_?Box_dtor$' <<<"$SYMS"; then
  fail "an unspecialized template destructor 'Box_dtor' was emitted; whether Box<T> needs a destructor at all DEPENDS ON T"
fi

# The ARC-critical negative. `Box<u64>`'s field is a u64: releasing it would
# treat an integer as a heap pointer. No destructor may exist for the two
# value-type instantiations.
for unwanted in 'Box\$u64_dtor' 'Box\$u32_dtor'; do
  if grep -q "$unwanted" <<<"$SYMS"; then
    fail "a destructor \"$unwanted\" was emitted for a VALUE-typed instantiation; its field is an integer, and releasing it would treat that integer as a heap pointer"
  fi
done
echo "  symbols ok: Box\$u64/u32/Node specialized, Box\$Node_dtor only, no template, no value-type destructor"

# ---------------------------------------------------------------------------
# Step 2b — the INSTANTIATION BOUND, asserted as a refusal.
#
# GAP-0040 recorded that `f<T>` calling `f<Something<T>>` would queue
# specializations forever, unguarded because generic classes did not exist to
# build the infinite type with. `recursive_reject.dart` is that program. The
# only two possible behaviours are "reject" and "hang", so this step runs
# under a TIMEOUT and treats a hang as a failure in its own right -- a bound
# that is merely slow is not a bound.
# ---------------------------------------------------------------------------
REJECT_LOG="$WORKDIR/reject.log"
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(timeout 120)
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(gtimeout 120)
else
  TIMEOUT_CMD=()
fi
( cd "$EXAMPLE_DIR" && "${TIMEOUT_CMD[@]}" "${DCC_CMD[@]}" build --mode bare \
    --target bare-x86_64 recursive_reject.dart -o "$WORKDIR/reject.o" ) \
    >"$REJECT_LOG" 2>&1
REJECT_STATUS=$?
if [[ $REJECT_STATUS -eq 124 ]]; then
  fail "recursive_reject.dart HUNG the compiler — monomorphization is queueing specializations forever, which is exactly what GAP-0040 said would happen without a bound"
fi
if [[ $REJECT_STATUS -eq 0 ]]; then
  fail "recursive_reject.dart COMPILED. It instantiates Box one level deeper on every call, so a successful build means the instantiation set was silently truncated somewhere — worse than either rejecting or hanging, because the emitted program is not the one that was written"
fi
grep -q "levels deep" "$REJECT_LOG" \
  || fail "recursive_reject.dart was rejected, but not by the instantiation bound — the message should name the nesting depth that ran away. Got: $(tr '\n' ' ' <"$REJECT_LOG")"
echo "  instantiation bound ok: recursion through a type parameter is refused by name, not by hanging"

# ---------------------------------------------------------------------------
# Step 3 — ARC COUNTS (CLAUDE.md's elision rule).
#
# Exact per-function Alloc/Retain/Release at the DC-IR level, which is the
# only level they are countable at (they are inlined, not symbols, by the
# time the backend is done -- ADR-0024). Every number below is hand-derived
# in docs/decisions/0054-generic-classes.md and asserted here so that a
# regression in elision -- which is invisible at runtime and catastrophic in
# aggregate -- is a test failure.
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

# A value-typed instantiation: one Alloc, one Release, and NOTHING else.
# A retain here would mean the box's own integer field was being ARC'd.
arc_is 'boxU64'      'alloc=1 retain=0 release=1 makeweak=0 weakload=0 dropweak=0'
arc_is 'boxU32'      'alloc=1 retain=0 release=1 makeweak=0 weakload=0 dropweak=0'
arc_is 'boxU64Field' 'alloc=1 retain=0 release=1 makeweak=0 weakload=0 dropweak=0'
arc_is 'boxU32Field' 'alloc=1 retain=0 release=1 makeweak=0 weakload=0 dropweak=0'
arc_is 'boxBoth'     'alloc=2 retain=0 release=2 makeweak=0 weakload=0 dropweak=0'

# The reference-typed instantiation, where the shape genuinely differs.
# Derivation, because this is the one number that is not obvious and the one
# an elision regression would move:
#
#   Node(v)              Alloc                                 alloc 1
#   Box<Node>(n)         Alloc                                 alloc 2
#                        Retain n   -- storing a BORROWED ctor
#                                      param into a field the new
#                                      object outlives (ADR-0020)  retain 1
#   b.unwrap()           Retain got -- aliasing a borrowed
#                                      return into a local (ADR-0017)
#   return got.n         Release n, Release b, Release got
#
# ADR-0025's pass 3 USED TO delete the `got` retain/release pair -- nothing
# between them releases `got`, so it looked like a redundant alias round trip
# -- and this line used to assert the elided 1/2.
#
# CHANGED BY ADR-0063 to 2/3. This is an ATTRIBUTED loss of elision, not a
# re-pin to whatever the build now reports, and this function is where
# GAP-0054 was first noticed.
#
# `Release b` sits between the retain and its match, and `Release b` runs
# `Box$Node_dtor`, which releases `b.value` -- THE VERY OBJECT `got` aliases.
# So "no release of `got` in between" was true and beside the point: the
# object could reach zero anyway. It did not actually crash here, and the
# reason it did not is worth keeping: `got.n` is lowered BEFORE
# `_releaseHeapLocals` emits anything, so the freed object was never read.
# That is a property of how dcc-lower orders a return, in a different file,
# asserted nowhere. `examples/m3-elide-alias` is the same shape with the read
# moved after the release, and it returned 198 instead of 110.
#
# So the +1/+1 here buys the removal of a use-after-free that this target
# could not have detected, since the counts balanced and the heap returned to
# baseline either way. Every other function in this file is unchanged.
#
# The result is still balanced, which is what makes it correct rather than
# merely larger: the Node carries +3 (its Alloc, the field-store retain, and
# the alias retain) against -3 (the local release, Box\$Node_dtor's release of
# the field, and the alias release), and the Box carries +1/-1.
arc_is 'boxNode'     'alloc=2 retain=2 release=3 makeweak=0 weakload=0 dropweak=0'

# The synthesized per-instantiation destructor: exactly one Release, for the
# one heap-typed field the instantiation has.
arc_is 'Box\$Node_dtor' 'alloc=0 retain=0 release=1 makeweak=0 weakload=0 dropweak=0'

# The specialized methods borrow their receiver and return a borrowed value
# (ADR-0019's default): no ARC of their own at all, at EVERY instantiation.
arc_is 'Box\$u64_unwrap'  'alloc=0 retain=0 release=0 makeweak=0 weakload=0 dropweak=0'
arc_is 'Box\$u32_unwrap'  'alloc=0 retain=0 release=0 makeweak=0 weakload=0 dropweak=0'
arc_is 'Box\$Node_unwrap' 'alloc=0 retain=0 release=0 makeweak=0 weakload=0 dropweak=0'
echo "  ARC counts ok: value-typed instantiations carry no retain at all, Box\$Node_dtor releases exactly its one heap field"

# ---------------------------------------------------------------------------
# Step 4 — BEHAVIOUR and LEAK, through the portable link helper.
# ---------------------------------------------------------------------------
dc_link "$WORKDIR/generic_class_test" "$EXAMPLE_DIR/main.c" \
  "$WORKDIR/generic_class.o" "$SRC"
echo "  link mode: $DC_LINK_MODE"

OUT="$("$WORKDIR/generic_class_test")"; STATUS=$?
echo "$OUT"
[[ $STATUS -eq 0 ]] || fail "generic_class_test exited $STATUS — see the message above"
grep -q "GENERIC-CLASS: all correct" <<<"$OUT" || fail "unexpected output: $OUT"

echo "GENERIC-CLASS: PASS — per-instantiation layout, per-instantiation destructor, no template symbol, exact ARC counts, heap at baseline across three instantiations"
exit 0
