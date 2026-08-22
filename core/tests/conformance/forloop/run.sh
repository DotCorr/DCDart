#!/usr/bin/env bash
# core/tests/conformance/forloop/run.sh
#
# Conformance target for `for` loops (ADR-0050).
#
# `withContinue` is why this target exists. Dart's `continue` inside a `for`
# must still RUN THE UPDATE before re-testing. Appending the update to the
# loop body -- the obvious desugaring -- skips it on every `continue`, which
# does not produce a wrong answer: it produces an infinite loop. The update
# therefore gets its own block, and `continue` targets that block rather than
# the header.
#
# Usage:
#   bash core/tests/conformance/forloop/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-for"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWFOR="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "FOR: FAIL — $1" >&2; exit 1; }
setup_error() { echo "FOR: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/forloop.dart" ]] || setup_error "missing $EXAMPLE_DIR/forloop.dart"
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

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-for.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    forloop.dart -o "$WORKDIR/forloop.o" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed"; }

if command -v llvm-nm >/dev/null 2>&1; then
  VERIFY_OUT="$(DCDART_ALLOWFOR="$ALLOWFOR" bash "$VERIFY_SCRIPT" "$WORKDIR/forloop.o" 2>&1)"
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
    forloop.dart -o "$WORKDIR/forloop_host.o" --emit-header "$WORKDIR/forloop.h" ) \
    >"$WORKDIR/hostbuild.log" 2>&1 \
  || { cat "$WORKDIR/hostbuild.log" >&2; fail "dcc build --target host failed"; }

[[ -f "$WORKDIR/forloop.h" ]] || fail "--emit-header produced no header"

clang -I"$WORKDIR" -o "$WORKDIR/forloop_test" "$EXAMPLE_DIR/main.c" \
  "$WORKDIR/forloop_host.o" >"$WORKDIR/link.log" 2>&1 \
  || { cat "$WORKDIR/link.log" >&2; fail "hosted link failed"; }

OUT="$("$WORKDIR/forloop_test")"; STATUS=$?
echo "$OUT"
[[ $STATUS -eq 0 ]] || fail "rodata_test exited $STATUS — a value read back wrong"
grep -q "FOR: all correct" <<<"$OUT" || fail "unexpected output: $OUT"

echo "FOR: PASS — for-loops compile and run correctly, including nesting, break, and continue running the update clause before re-testing"
exit 0
