#!/usr/bin/env bash
# core/tests/conformance/closure/run.sh
#
# Conformance target for NON-CAPTURING CLOSURES (ADR-0057).
#
# Three assertions carry this target, and only the last one is about values:
#
#   HOISTING      Every local function must appear in the symbol table under a
#                 name qualified by its enclosing function, and no unqualified
#                 one may exist. Read from the object rather than inferred from
#                 behaviour: an implementation that inlined every local
#                 function into its caller would compute identical answers
#                 while quietly making `dbl` uncallable from two sites and
#                 making two same-named locals in different functions collide.
#
#   ELISION       `viaTopLevel` and `viaClosure` are the same program written
#                 two ways -- consuming callee at top level vs. inside the
#                 body. Their ARC instruction counts must be IDENTICAL, which
#                 is the whole claim of the narrow subset: a non-capturing
#                 closure call is a DIRECT call to a statically known callee,
#                 so `Call.argOwnership` is exact and dc-elide's pass-4
#                 call-consumed case fires through it unchanged. Asserted with
#                 `dc-objdump --arc`, because two programs can agree on every
#                 value while one retains and releases twice as often.
#
#                 This is the property docs/escalations/0008 says is LOST the
#                 moment a closure becomes a VALUE (argOwnership is then not
#                 derivable at all, so every such call site is an elision
#                 barrier). It is asserted here while it still holds, so that
#                 a later change which quietly gives it up cannot pass.
#
#   BEHAVIOUR     Ordinary values, plus 500 leak-free heap cycles -- well past
#                 the 64-slot arena, so a single leaked slot per call could not
#                 survive.
#
# Usage:
#   bash core/tests/conformance/closure/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-closure"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "CLOSURE: FAIL — $1" >&2; exit 1; }
setup_error() { echo "CLOSURE: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/closure.dart" ]] || setup_error "missing $EXAMPLE_DIR/closure.dart"
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

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-closure.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/closure.o"
BIN="$WORKDIR/closure_test"

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine (rule 1).
#
# This matters more than usual here: hoisting invents SYMBOLS that no line of
# source names. If the hoisted name were ever emitted as a reference without a
# definition, this is where it would show up.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    closure.dart -o "$OBJ" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed (log above)"; }
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"

command -v llvm-nm >/dev/null 2>&1 \
  || fail "llvm-nm not found on PATH (required by verify-freestanding.sh), see docs/known-gaps.md GAP-0001"

VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$OBJ" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
[[ $VERIFY_STATUS -eq 0 ]] && grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT" \
  || fail "verify-freestanding.sh did not report a clean pass for $OBJ — a hoisted local function must be DEFINED here, never referenced from elsewhere"

# ---------------------------------------------------------------------------
# Step 1b — HOISTING, read out of the symbol table.
# ---------------------------------------------------------------------------
SYMS="$(llvm-nm "$OBJ" 2>/dev/null)"
[[ -n "$SYMS" ]] || fail "llvm-nm produced no symbols; the checks below would pass vacuously"

for want in 'twiceSum\$dbl' 'addThree\$f' 'clampTo\$f' 'factorial\$go' \
            'pipeline\$inc' 'pipeline\$incTwice' 'viaClosure\$dropLocal' \
            'makeViaClosure\$mk'; do
  grep -q "$want" <<<"$SYMS" \
    || fail "expected a hoisted symbol matching \"$want\"; got: $(tr '\n' ' ' <<<"$SYMS")"
done

# The qualifier is not decoration. `addThree` and `clampTo` both name their
# local `f`; an unqualified hoist would emit `f` twice and one would silently
# win. Assert the unqualified names are absent.
for unwanted in 'dbl' 'go' 'inc' 'incTwice' 'dropLocal' 'mk' 'f'; do
  if grep -qE "[[:space:]]_?${unwanted}\$" <<<"$SYMS"; then
    fail "an UNQUALIFIED hoisted symbol '${unwanted}' was emitted; two local functions with the same name in different enclosing functions would collide"
  fi
done
echo "  hoisting ok: 8 enclosing-qualified symbols, no unqualified local-function name"

# ---------------------------------------------------------------------------
# Step 1c — ELISION. `dc-objdump --arc` at the DC-IR level, which is the only
# place these are countable (they are inlined, not symbols, by the time the
# backend is done -- see core/dc-objdump/bin/dc_objdump.dart's header).
# ---------------------------------------------------------------------------
ARC="$(cd "$CORE_DIR/dc-objdump" && dart bin/dc_objdump.dart --arc "$EXAMPLE_DIR/closure.dart" 2>&1)"
[[ $? -eq 0 ]] || { echo "$ARC" >&2; fail "dc-objdump --arc failed (output above)"; }
echo "$ARC" | sed 's/^/  /'

arc_counts() {
  # Prints just the "alloc=.. retain=.. ..." tail for one function, so two
  # functions with different names can be compared directly.
  grep -E "^  $1: " <<<"$ARC" | sed "s/^  $1: //"
}

TOP="$(arc_counts 'viaTopLevel')"
CLO="$(arc_counts 'viaClosure')"
[[ -n "$TOP" && -n "$CLO" ]] \
  || fail "dc-objdump --arc did not report both viaTopLevel and viaClosure; got:
$ARC"
[[ "$TOP" == "$CLO" ]] \
  || fail "ARC counts differ between the top-level and closure spellings of the SAME program — a non-capturing closure call must stay a direct call with exact argOwnership (docs/escalations/0008):
  viaTopLevel: $TOP
  viaClosure:  $CLO"

CALLEE_TOP="$(arc_counts 'dropTop')"
CALLEE_CLO="$(arc_counts 'viaClosure\$dropLocal')"
[[ -n "$CALLEE_TOP" && -n "$CALLEE_CLO" ]] \
  || fail "dc-objdump --arc did not report both consuming callees; got:
$ARC"
[[ "$CALLEE_TOP" == "$CALLEE_CLO" ]] \
  || fail "ARC counts differ between the top-level and hoisted spellings of the SAME @owned-consuming callee:
  dropTop:              $CALLEE_TOP
  viaClosure\$dropLocal: $CALLEE_CLO"

# And the guard against a vacuous match: if elision were switched off, or if
# the closure call site failed to record ownership, `viaTopLevel` would carry a
# live retain/release pair. It must not -- ADR-0031's call-consumed case is
# exactly what removes it, and that is what "identical" is being measured
# against.
[[ "$TOP" == "alloc=1 retain=0 release=0 makeweak=0 weakload=0 dropweak=0" ]] \
  || fail "viaTopLevel's ARC counts are \"$TOP\", expected \"alloc=1 retain=0 release=0 makeweak=0 weakload=0 dropweak=0\" — if the retain/release pair is still present, the equality check above is comparing two UNELIDED programs and proves nothing"
# The other ARC direction: a local function that CONSTRUCTS and returns the
# object. Ownership must transfer out of it unreleased, exactly as out of the
# top-level spelling -- a mismatch here is a retain the caller does not own.
MK_TOP="$(arc_counts 'makeViaTopLevel')"
MK_CLO="$(arc_counts 'makeViaClosure')"
[[ -n "$MK_TOP" && -n "$MK_CLO" ]] \
  || fail "dc-objdump --arc did not report both makeViaTopLevel and makeViaClosure; got:
$ARC"
[[ "$MK_TOP" == "$MK_CLO" ]] \
  || fail "ARC counts differ between the top-level and closure spellings of the heap-CONSTRUCTING program:
  makeViaTopLevel: $MK_TOP
  makeViaClosure:  $MK_CLO"

echo "  elision ok: identical ARC counts either spelling in both ARC directions, and the @owned pair is genuinely elided"

# ---------------------------------------------------------------------------
# Step 2 — link and run. Delegated to the shared helper, which picks a link
# path per host (freestanding on Linux/x86-64, hosted elsewhere) and sets
# DC_LINK_MODE. See tests/conformance/_lib/hosted-link.sh for why.
# ---------------------------------------------------------------------------
source "$CORE_DIR/tests/conformance/_lib/hosted-link.sh"
dc_link "$BIN" "$EXAMPLE_DIR/main.c" "$OBJ" "$EXAMPLE_DIR/closure.dart"

# ---------------------------------------------------------------------------
# Step 3 — run. main.c has no stdio (the Linux path links -nostdlib), so the
# exit code is the report:
#   1 arena not at baseline before any call
#   2 twiceSum (named local function, two call sites)
#   3 addThree (function expression bound to a final local)
#   4 clampTo  (block body with a branch inside the hoisted function)
#   5 factorial (self-recursion)
#   6 pipeline (local function calling an earlier sibling)
#   7 viaTopLevel leaked   8 viaClosure leaked   9 the two disagreed
#   10 makeViaTopLevel leaked  11 makeViaClosure leaked  12 the two disagreed
# ---------------------------------------------------------------------------
"$BIN"
ACTUAL=$?
[[ $ACTUAL -eq 0 ]] \
  || fail "closure_test exited $ACTUAL — see this file's step 3 and core/examples/m2-closure/main.c"

echo "CLOSURE: PASS — non-capturing local functions and function expressions hoist to enclosing-qualified static symbols, ARC counts are byte-identical to the top-level spelling (elision fires through the call site), $DC_LINK_MODE link, 500 leak-free heap cycles"
exit 0
