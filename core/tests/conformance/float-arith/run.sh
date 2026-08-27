#!/usr/bin/env bash
# core/tests/conformance/float-arith/run.sh
#
# Conformance target for float arithmetic (ADR-0065): f32/f64 `+ - * /`,
# ordered comparisons, `==`/`!=`, unary minus, literals, and all six
# prelude conversions.
#
# What this target exists to prove, and why a looser test would not:
#
#   BIT-EXACT AGAINST C. Every isolated operator's result is memcmp'd
#   against C computing the identical IEEE operation — a tolerance-based
#   check would quietly accept a wrong rounding mode, a double-rounded
#   f32 literal, or an f32 computation taking an f64 detour.
#
#   IEEE EDGE SEMANTICS, not just round numbers. NaN makes every ordered
#   comparison false and `!=` true; NaN propagates; `-(0.0)` is `-0.0`;
#   `1.0/0.0` is +inf without a trap (floats have `/`, integers keep `~/`
#   — ADR-0036's float half is superseded, its integer half is not); and
#   `.toU64trunc()` SATURATES (clamp + NaN->0) where plain fptoui would be
#   poison.
#
#   FREESTANDING WITH HARDWARE FLOAT. The bare-x86_64 object must contain
#   no `__addsf3`-style soft-float or `__fixunssfdi`-style conversion
#   libcalls — every float op must be a real SSE2 instruction, or
#   verify-freestanding.sh fails on the undefined symbol (CLAUDE.md rule 1).
#
# Usage:
#   bash core/tests/conformance/float-arith/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m4-float-arith"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "FLOATARITH: FAIL — $1" >&2; exit 1; }
setup_error() { echo "FLOATARITH: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/floatarith.dart" ]] || setup_error "missing $EXAMPLE_DIR/floatarith.dart"
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

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-floatarith.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine. This is
# where a soft-float libcall would surface, as an undefined `__*` symbol.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    floatarith.dart -o "$WORKDIR/floatarith.o" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed"; }

if command -v llvm-nm >/dev/null 2>&1; then
  VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$WORKDIR/floatarith.o" 2>&1)"
  echo "$VERIFY_OUT"
  grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT" \
    || fail "float codegen introduced an undefined symbol — a soft-float or conversion libcall is a CLAUDE.md rule 1 violation"
else
  fail "llvm-nm not found on PATH (required by verify-freestanding.sh)"
fi

# ---------------------------------------------------------------------------
# Step 2 — BEHAVIOUR. Build for the host, link ordinarily, run. Links
# against real libc like demo-collatz does, so it runs natively on macOS,
# Linux and Windows; libm is only used by the C SIDE of the harness (NAN/
# INFINITY/isnan), never by the DCDart object.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host \
    floatarith.dart -o "$WORKDIR/floatarith_host.o" --emit-header "$WORKDIR/floatarith.h" ) \
    >"$WORKDIR/hostbuild.log" 2>&1 \
  || { cat "$WORKDIR/hostbuild.log" >&2; fail "dcc build --target host failed"; }

[[ -f "$WORKDIR/floatarith.h" ]] || fail "--emit-header produced no header"
grep -q "double addF64(double" "$WORKDIR/floatarith.h" \
  || fail "header maps f64 to something other than double (c_header.dart's DCFloat case)"
grep -q "float mulF32(float" "$WORKDIR/floatarith.h" \
  || fail "header maps f32 to something other than float (c_header.dart's DCFloat case)"

clang -I"$WORKDIR" -o "$WORKDIR/floatarith_test" "$EXAMPLE_DIR/main.c" \
  "$WORKDIR/floatarith_host.o" -lm >"$WORKDIR/link.log" 2>&1 \
  || { cat "$WORKDIR/link.log" >&2; fail "hosted link failed"; }

OUT="$("$WORKDIR/floatarith_test")"; STATUS=$?
echo "$OUT"
[[ $STATUS -eq 0 ]] || fail "floatarith_test exited $STATUS — a value came back with the wrong bits"
grep -q "FLOATARITH: all correct" <<<"$OUT" || fail "unexpected output: $OUT"

echo "FLOATARITH: PASS — f32/f64 arithmetic, comparisons, literals and conversions bit-exact against C; NaN/inf/-0.0 follow IEEE; truncation saturates; the bare object stays freestanding"
exit 0
