#!/usr/bin/env bash
# core/tests/conformance/methods/run.sh
#
# Conformance target for instance methods (ADR-0043).
#
# A method on a HeapObject subclass lowers to an ordinary function whose FIRST
# parameter is the receiver -- the shape `_buildDestructor` (ADR-0022) already
# synthesized, and the shape C uses. No dispatch: the concrete class is
# statically known at every call site.
#
# The case worth having a target for is a method calling ANOTHER method on the
# receiver (`netAfterDeposit` -> `afterDeposit`), which is what breaks if the
# receiver is not threaded through correctly, and two live receivers in one
# function so the argument genuinely varies rather than being constant-folded.
#
# Builds freestanding first (the spine check must still pass -- a method is
# just a function, and must not drag in a runtime), then builds for the host
# and runs against the GENERATED header, so a wrong receiver type is a compile
# error here rather than silent corruption.
#
# Usage:
#   bash core/tests/conformance/methods/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-methods"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "METHODS: FAIL — $1" >&2; exit 1; }
setup_error() { echo "METHODS: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/methods.dart" ]] || setup_error "missing $EXAMPLE_DIR/methods.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing $EXAMPLE_DIR/main.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"

if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi
command -v clang >/dev/null 2>&1 || fail "clang not found on PATH"

OBJDUMP=""
for c in llvm-objdump objdump; do
  if command -v "$c" >/dev/null 2>&1; then OBJDUMP="$c"; break; fi
done
[[ -n "$OBJDUMP" ]] || fail "neither llvm-objdump nor objdump found; the layout half of this harness reads real bytes and cannot run without one"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-methods.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    methods.dart -o "$WORKDIR/methods.o" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed"; }

if command -v llvm-nm >/dev/null 2>&1; then
  VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$WORKDIR/methods.o" 2>&1)"
  echo "$VERIFY_OUT"
  grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT" \
    || fail "static data introduced an undefined symbol — a DEFINED global must never do that"
else
  fail "llvm-nm not found on PATH (required by verify-freestanding.sh)"
fi

# ---------------------------------------------------------------------------
# Step 2 — BEHAVIOUR. Build for the host, link ordinarily, run.
#
# No Linux/x86-64 gate: this links against real libc like
# examples/demo-collatz does, so it runs natively on macOS, Linux and Windows.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host \
    methods.dart -o "$WORKDIR/methods_host.o" --emit-header "$WORKDIR/methods.h" ) \
    >"$WORKDIR/hostbuild.log" 2>&1 \
  || { cat "$WORKDIR/hostbuild.log" >&2; fail "dcc build --target host failed"; }

[[ -f "$WORKDIR/methods.h" ]] || fail "--emit-header produced no header"

clang -I"$WORKDIR" -o "$WORKDIR/methods_test" "$EXAMPLE_DIR/main.c" \
  "$WORKDIR/methods_host.o" >"$WORKDIR/link.log" 2>&1 \
  || { cat "$WORKDIR/link.log" >&2; fail "hosted link failed"; }

OUT="$("$WORKDIR/methods_test")"; STATUS=$?
echo "$OUT"
[[ $STATUS -eq 0 ]] || fail "rodata_test exited $STATUS — a value read back wrong"
grep -q "METHODS: all correct" <<<"$OUT" || fail "unexpected output: $OUT"

echo "METHODS: PASS — instance methods lower to functions with the receiver as parameter 0, freestanding-clean, and compute correctly including a method calling another method on the receiver"
exit 0
