#!/usr/bin/env bash
# core/tests/conformance/float-pointer/run.sh
#
# Conformance target for float BUFFERS (ADR-0065): `Pointer<f32>` /
# `Pointer<f64>` load/store over Heap-allocated memory, reduced by a dot
# product — the exact shape of the ML kernels (matmul/softmax/layernorm)
# this feature was authorized for.
#
# What this target exists to prove, and why the arithmetic target cannot:
#
#   LOAD/STORE WIDTH. A `Pointer<f32>` store must touch exactly 4 bytes; a
#   wrong width corrupts the NEIGHBORING element, not the one stored. The
#   harness therefore probes every element of a filled buffer from C
#   individually, then checks f64 at stride 8 through the same code path.
#
#   f32 ACCUMULATION. The dot product's loop-carried sum is compared
#   BIT-EXACTLY against C accumulating in float — at n=1000+ an f64 detour
#   in the accumulator rounds differently and fails the memcmp.
#
#   LEAK-FREEDOM PER CALL. dc_heap_live is asserted back at zero after
#   EVERY call, m2-rawheap's discipline: a leak balanced by a double-free
#   nets to zero across a run.
#
# Usage:
#   bash core/tests/conformance/float-pointer/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m4-float-dot"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "FLOATDOT: FAIL — $1" >&2; exit 1; }
setup_error() { echo "FLOATDOT: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/dot.dart" ]] || setup_error "missing $EXAMPLE_DIR/dot.dart"
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

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-floatdot.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    dot.dart -o "$WORKDIR/dot.o" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed"; }

if command -v llvm-nm >/dev/null 2>&1; then
  VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$WORKDIR/dot.o" 2>&1)"
  echo "$VERIFY_OUT"
  grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT" \
    || fail "float buffer codegen introduced an undefined symbol — a soft-float or memcpy-style libcall is a CLAUDE.md rule 1 violation"

  # A raw-allocation-only module must still emit the heap globals — the
  # exact regression tests/conformance/rawheap/ pinned down (ADR-0058's
  # needsHeap predicate), re-asserted here because this module reaches the
  # heap through float-typed code paths that predicate has never seen.
  SYMS="$(llvm-nm "$WORKDIR/dot.o" 2>/dev/null)"
  for sym in dc_heap dc_heap_bump dc_heap_free dc_heap_live dc_heap_sizes; do
    grep -qE "[[:space:]]$sym\$" <<<"$SYMS" \
      || fail "heap global \"$sym\" is missing from an object that allocates — see ADR-0058's needsHeap predicate"
  done
  echo "  heap globals ok: all five emitted for a float-buffer module"
else
  fail "llvm-nm not found on PATH (required by verify-freestanding.sh)"
fi

# ---------------------------------------------------------------------------
# Step 2 — BEHAVIOUR. Build for the host, link ordinarily, run.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host \
    dot.dart -o "$WORKDIR/dot_host.o" --emit-header "$WORKDIR/dot.h" ) \
    >"$WORKDIR/hostbuild.log" 2>&1 \
  || { cat "$WORKDIR/hostbuild.log" >&2; fail "dcc build --target host failed"; }

[[ -f "$WORKDIR/dot.h" ]] || fail "--emit-header produced no header"

clang -I"$WORKDIR" -o "$WORKDIR/dot_test" "$EXAMPLE_DIR/main.c" \
  "$WORKDIR/dot_host.o" >"$WORKDIR/link.log" 2>&1 \
  || { cat "$WORKDIR/link.log" >&2; fail "hosted link failed"; }

OUT="$("$WORKDIR/dot_test")"; STATUS=$?
echo "$OUT"
[[ $STATUS -eq 0 ]] || fail "dot_test exited $STATUS — a buffer element or reduction came back wrong, or the heap leaked"
grep -q "FLOATDOT: all correct" <<<"$OUT" || fail "unexpected output: $OUT"

echo "FLOATDOT: PASS — f32/f64 buffers written and read through Pointer<T> at the right stride, dot products bit-exact against C's own f32/f64 accumulation up to n=4096, dc_heap_live back to zero after every call"
exit 0
