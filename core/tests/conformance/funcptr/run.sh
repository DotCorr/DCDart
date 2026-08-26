#!/usr/bin/env bash
# core/tests/conformance/funcptr/run.sh
#
# Conformance target for FUNCTION POINTERS and INDIRECT CALLS (ADR-0060).
#
# Five assertions carry this target, and the third is the one the unit exists
# for.
#
#   FREESTANDING  A `FuncRef` names a symbol. If the symbol were ever
#                 referenced without being defined -- a hoisted local torn off
#                 but never emitted, say -- CLAUDE.md rule 1 is where it shows.
#
#   INDIRECTION   The object must contain a real indirect branch. Read from the
#                 disassembly, not inferred from behaviour: an implementation
#                 that constant-folded every pointer back to its target would
#                 compute identical answers while proving nothing about the
#                 feature. `dispatch` is the case no optimizer can devirtualize
#                 -- the pointer is chosen at run time and crosses a function
#                 boundary.
#
#   ELISION       `viaTopLevel`, `viaClosure`, `viaFuncPtr` and `viaTopFuncPtr`
#                 are the SAME program: an `@owned`-consuming callee reached by
#                 a top-level name, a hoisted local name, a pointer to the
#                 hoisted local, and a pointer to the top-level one. Their ARC
#                 counts must be IDENTICAL and must be the ELIDED ones.
#
#                 docs/escalations/0008 §3 predicted the opposite: that
#                 `argOwnership` is "not conservatively derivable -- it is not
#                 derivable at all" through a value, so every indirect call
#                 site becomes an elision barrier and the two pointer
#                 spellings come back as `retain=1 release=1`. ADR-0060's
#                 answer is to carry ownership in the pointer's TYPE. This
#                 check is that answer, measured. If a later change gives it
#                 up, this is what fails.
#
#                 The BORROWED direction is asserted too, at its own exact
#                 counts. An elision pass that dropped a load-bearing pair
#                 would make the first three numbers look even better while
#                 introducing a use-after-free, so "fewer retains" is not on
#                 its own the thing being checked.
#
#   HEADER        The emitted C header must COMPILE. A function pointer is where
#                 C's declarator syntax stops being "type then name", in two
#                 different ways (parameter, and return), and neither is
#                 checkable by reading the file -- the first version of this
#                 emitter produced a header that looked plausible and did not
#                 parse.
#
#   BEHAVIOUR     Ordinary values through every shape, a DCDart higher-order
#                 function called from C with a C function pointer, and 2000
#                 leak-free heap cycles with `dc_heap_live` (ADR-0058) checked
#                 back at zero after every single call.
#
# Usage:
#   bash core/tests/conformance/funcptr/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m3-funcptr"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "FUNCPTR: FAIL — $1" >&2; exit 1; }
setup_error() { echo "FUNCPTR: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/funcptr.dart" ]] || setup_error "missing $EXAMPLE_DIR/funcptr.dart"
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
command -v clang >/dev/null 2>&1 || fail "clang not found on PATH, see docs/known-gaps.md GAP-0001"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-funcptr.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/funcptr.o"
BIN="$WORKDIR/funcptr_test"

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine (rule 1).
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    funcptr.dart -o "$OBJ" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed (log above)"; }
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"

command -v llvm-nm >/dev/null 2>&1 \
  || fail "llvm-nm not found on PATH (required by verify-freestanding.sh), see docs/known-gaps.md GAP-0001"

VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$OBJ" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
[[ $VERIFY_STATUS -eq 0 ]] && grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT" \
  || fail "verify-freestanding.sh did not report a clean pass for $OBJ — a function torn off as a pointer must be DEFINED here, never referenced from elsewhere"

# ---------------------------------------------------------------------------
# Step 1b — INDIRECTION, read out of the disassembly.
#
# `dispatch` selects between two function pointers at run time via `chooser`,
# so no amount of inlining can turn its call into a direct one. On x86-64 an
# indirect call/jump through a register is `ff d0`-family: `call *%reg` or
# `jmp *%reg` (the latter when LLVM tail-calls, which it does here). The check
# accepts either, because which one appears is an optimizer decision and not
# something this target is asserting.
# ---------------------------------------------------------------------------
if command -v llvm-objdump >/dev/null 2>&1; then
  DISASM="$(llvm-objdump -d --disassemble-symbols=dispatch "$OBJ" 2>/dev/null)"
  if [[ -n "$DISASM" ]]; then
    grep -qE '(call|jmp)q?[[:space:]]+\*' <<<"$DISASM" \
      || fail "no indirect call or jump in \"dispatch\" — a run-time-selected function pointer was folded into a direct call, so this target is not testing an indirect call at all:
$DISASM"
    echo "  indirection ok: dispatch contains a real indirect branch through a register"
  else
    echo "  indirection: SKIPPED (llvm-objdump produced no output for dispatch)"
  fi
else
  echo "  indirection: SKIPPED (llvm-objdump not on PATH)"
fi

# ---------------------------------------------------------------------------
# Step 1c — ELISION. `dc-objdump --arc` at the DC-IR level, which is the only
# place these are countable (they are inlined, not symbols, by the time the
# backend is done).
# ---------------------------------------------------------------------------
ARC="$(cd "$CORE_DIR/dc-objdump" && dart bin/dc_objdump.dart --arc "$EXAMPLE_DIR/funcptr.dart" 2>&1)"
[[ $? -eq 0 ]] || { echo "$ARC" >&2; fail "dc-objdump --arc failed (output above)"; }
echo "$ARC" | sed 's/^/  /'

arc_counts() {
  grep -E "^  $1: " <<<"$ARC" | sed "s/^  $1: //"
}

ELIDED="alloc=1 retain=0 release=0 makeweak=0 weakload=0 dropweak=0"

# All four spellings of the same program, asserted against the ABSOLUTE elided
# counts rather than only against each other -- four unelided programs would
# agree with each other perfectly and prove nothing.
for fn in viaTopLevel viaClosure viaFuncPtr viaTopFuncPtr; do
  GOT="$(arc_counts "$fn")"
  [[ -n "$GOT" ]] || fail "dc-objdump --arc did not report $fn; got:
$ARC"
  [[ "$GOT" == "$ELIDED" ]] \
    || fail "$fn's ARC counts are \"$GOT\", expected \"$ELIDED\".
  viaTopLevel/viaClosure reach an @owned-consuming callee by NAME; viaFuncPtr/
  viaTopFuncPtr reach the same callee through a function POINTER. All four must
  elide the retain/release pair. If the two pointer spellings show retain=1
  release=1, the indirect call has become an elision barrier and
  docs/escalations/0008 §3's prediction has come true — ownership is no longer
  reaching dc-elide through DCFuncPtr. See ADR-0060."
done
echo "  elision ok: all four spellings elide the @owned pair — an indirect call site is NOT a barrier"

# The other direction, at its own exact counts. A pass that elided here would
# free the object while a live alias still points at it; "fewer retains" is not
# by itself the property being asserted.
BORROW="$(arc_counts 'borrowViaFuncPtr')"
BORROW_WANT="alloc=1 retain=1 release=2 makeweak=0 weakload=0 dropweak=0"
[[ "$BORROW" == "$BORROW_WANT" ]] \
  || fail "borrowViaFuncPtr's ARC counts are \"$BORROW\", expected \"$BORROW_WANT\" — a BORROWED indirect call's retain/release pair is load-bearing and must survive elision"
echo "  elision ok: the borrowed direction's pair survives, so the elision above is selective, not blanket"

# The hoisted local torn off as a value must still be a real symbol, not
# inlined away -- the tear-off is what ADR-0057 could not express.
SYMS="$(llvm-nm "$OBJ" 2>/dev/null)"
[[ -n "$SYMS" ]] || fail "llvm-nm produced no symbols; the check below would pass vacuously"
for want in 'localTearOff\$triple' 'viaFuncPtr\$dropLocal'; do
  grep -q "$want" <<<"$SYMS" \
    || fail "expected a hoisted symbol matching \"$want\" — a local function whose ADDRESS is taken must exist as a symbol; got: $(tr '\n' ' ' <<<"$SYMS")"
done
echo "  tear-off ok: hoisted local functions used as values exist as enclosing-qualified symbols"

# ---------------------------------------------------------------------------
# Step 1d — the emitted C HEADER must actually compile.
#
# A function pointer is where C's declarator syntax stops being "type then
# name": a pointer PARAMETER puts the identifier inside the parentheses, and a
# returned pointer wraps the whole call declarator
# (`uint64_t (*chooser(uint64_t a0))(uint64_t)`). Both spellings are in this
# module, and neither is checkable by reading the header — the first version of
# this emitter produced one that looked plausible and did not parse. Compiled,
# not inspected.
#
# What the header CANNOT say is `@owned` (GAP-0058); nothing here asserts
# otherwise.
# ---------------------------------------------------------------------------
HDR="$WORKDIR/funcptr.h"
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host \
    funcptr.dart -o "$WORKDIR/hdr.o" --emit-header "$HDR" ) >"$WORKDIR/hdrbuild.log" 2>&1 \
  || { cat "$WORKDIR/hdrbuild.log" >&2; fail "dcc build --emit-header failed (log above)"; }
grep -q 'uint64_t (\*a0)(uint64_t)' "$HDR" \
  || fail "the emitted header does not declare applyTwice's function-pointer PARAMETER as a C function pointer; got: $(grep applyTwice "$HDR")"
grep -q 'uint64_t (\*chooser(uint64_t a0))(uint64_t)' "$HDR" \
  || fail "the emitted header does not declare chooser's function-pointer RETURN with C's outward declarator syntax; got: $(grep chooser "$HDR")"
printf '#include "%s"\nint main(void){return 0;}\n' "$HDR" > "$WORKDIR/hdrtest.c"
clang -std=c11 -c "$WORKDIR/hdrtest.c" -o "$WORKDIR/hdrtest.o" >"$WORKDIR/hdrcc.log" 2>&1 \
  || { cat "$WORKDIR/hdrcc.log" >&2; fail "the emitted C header does not compile (log above)"; }
echo "  header ok: function-pointer parameter and return both spelled in valid C, compiled to prove it"

# ---------------------------------------------------------------------------
# Step 2 — link and run. Delegated to the shared helper, which picks a link
# path per host (freestanding on Linux/x86-64, hosted elsewhere) and sets
# DC_LINK_MODE. See tests/conformance/_lib/hosted-link.sh for why.
# ---------------------------------------------------------------------------
source "$CORE_DIR/tests/conformance/_lib/hosted-link.sh"
dc_link "$BIN" "$EXAMPLE_DIR/main.c" "$OBJ" "$EXAMPLE_DIR/funcptr.dart"

# ---------------------------------------------------------------------------
# Step 3 — run. main.c has no stdio (the Linux path links -nostdlib), so the
# exit code is the report:
#    1 heap not at baseline before any call
#    2 dblTwice   3 incTwice      (function-pointer parameter)
#    4 applyTwice called from C with a C function pointer
#    5 localTearOff                (local function torn off into a value)
#    6 dispatch(0)  7 dispatch(1)  (pointer selected at run time)
#    8 viaTopLevel leaked   9 viaClosure leaked
#   10 viaFuncPtr leaked   11 viaTopFuncPtr leaked   12 the four disagreed
#   13 borrowViaFuncPtr wrong value  14 borrowViaFuncPtr leaked
#   15 voidCallback wrong value      16 voidCallback leaked
# ---------------------------------------------------------------------------
"$BIN"
ACTUAL=$?
[[ $ACTUAL -eq 0 ]] \
  || fail "funcptr_test exited $ACTUAL — see this file's step 3 and core/examples/m3-funcptr/main.c"

echo "FUNCPTR: PASS — function pointers carry their ARC convention in their type; an indirect call elides the @owned pair exactly as the direct call does, keeps the borrowed pair, $DC_LINK_MODE link, 2000 leak-free heap cycles"
exit 0
