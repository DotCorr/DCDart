#!/usr/bin/env bash
# core/tests/conformance/nested/run.sh
#
# Conformance target for nested while-loops (ADR-0044).
#
# ADR-0028 built `while` and refused to nest. Nothing tested nesting, so the
# refusal sat until oscortex_core hit it twice in one milestone while walking
# a PCI bus and a framebuffer. This target exists so that cannot recur.
#
# The three cases are chosen for what they would break:
#
#   innerWritesOuter  an INNER loop assigns a variable declared outside the
#                     OUTER loop -- the exact case ADR-0028's comment worried
#                     the analysis would mis-scope. It must be carried by both.
#   triple            three levels, so nothing depends on there being exactly
#                     two.
#   findPair          an if/else inside the inner loop with an early return out
#                     of BOTH, which exercises the phi-predecessor tracking
#                     ADR-0028 had to fix for the single-loop case.
#
# Usage:
#   bash core/tests/conformance/nested/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-nested"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "NESTED: FAIL — $1" >&2; exit 1; }
setup_error() { echo "NESTED: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/nested.dart" ]] || setup_error "missing $EXAMPLE_DIR/nested.dart"
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

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-nested.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    nested.dart -o "$WORKDIR/nested.o" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed"; }

if command -v llvm-nm >/dev/null 2>&1; then
  VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$WORKDIR/nested.o" 2>&1)"
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
    nested.dart -o "$WORKDIR/nested_host.o" --emit-header "$WORKDIR/nested.h" ) \
    >"$WORKDIR/hostbuild.log" 2>&1 \
  || { cat "$WORKDIR/hostbuild.log" >&2; fail "dcc build --target host failed"; }

[[ -f "$WORKDIR/nested.h" ]] || fail "--emit-header produced no header"

clang -I"$WORKDIR" -o "$WORKDIR/nested_test" "$EXAMPLE_DIR/main.c" \
  "$WORKDIR/nested_host.o" >"$WORKDIR/link.log" 2>&1 \
  || { cat "$WORKDIR/link.log" >&2; fail "hosted link failed"; }

OUT="$("$WORKDIR/nested_test")"; STATUS=$?
echo "$OUT"
[[ $STATUS -eq 0 ]] || fail "rodata_test exited $STATUS — a value read back wrong"
grep -q "NESTED: all correct" <<<"$OUT" || fail "unexpected output: $OUT"

echo "NESTED: PASS — nested while-loops compile, stay freestanding-clean, and compute correctly: an inner loop writing an outer-scope variable, triple nesting, and an early return out of both loops"
exit 0
