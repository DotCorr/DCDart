#!/usr/bin/env bash
# core/tests/conformance/rawheap/run.sh
#
# Conformance target for runtime-sized raw allocation (ADR-0058).
#
# What this target exists to prove, and why a smaller test would not:
#
#   GROWTH FROM ONE. `buildAndSum` starts a StrBuf at capacity 1 and appends
#   up to 500,000 bytes, so it reallocates at nearly every power of two --
#   about nineteen times. Each grow allocates a block at a size known only at
#   runtime, copies into it, and frees the old one. A test that allocated one
#   comfortable buffer would exercise none of that.
#
#   THE CLASS BOUNDARIES. Sizes 0 and 1 are below the smallest size class
#   (32 bytes) and must clamp UP rather than fail or hand back a short block.
#   The runtime class computation is `64 - ctlz(n-1)`, where an off-by-one
#   returns a block one class too small and the overflow is SILENT -- so the
#   sizes here sit on the boundaries rather than in the middle of classes.
#
#   LEAK-FREEDOM PER CALL, not per run. `dc_heap_live` is asserted back at
#   zero after EVERY size. A leak exactly balanced by a double-free would net
#   to zero across a whole run and pass an end-only check; per-call also says
#   which size regressed.
#
# Usage:
#   bash core/tests/conformance/rawheap/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-rawheap"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "RAWHEAP: FAIL — $1" >&2; exit 1; }
setup_error() { echo "RAWHEAP: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/rawheap.dart" ]] || setup_error "missing $EXAMPLE_DIR/rawheap.dart"
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

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-rawheap.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    rawheap.dart -o "$WORKDIR/rawheap.o" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed"; }

if command -v llvm-nm >/dev/null 2>&1; then
  VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$WORKDIR/rawheap.o" 2>&1)"
  echo "$VERIFY_OUT"
  grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT" \
    || fail "static data introduced an undefined symbol — a DEFINED global must never do that"
else
  fail "llvm-nm not found on PATH (required by verify-freestanding.sh)"
fi

# ---------------------------------------------------------------------------
# Step 1b — THE HEAP GLOBALS MUST BE EMITTED.
#
# A module that only calls `Heap.allocate` -- never constructing an ARC object
# -- still references `@dc_heap`. The emitter decides whether to emit the heap
# globals from a predicate over instruction types, and that predicate
# originally listed only the ARC ones, so this exact shape failed to compile
# with "use of undefined value '@dc_heap'". LLVM caught it, but the predicate
# has no exhaustiveness check of its own, so a future heap instruction can
# reintroduce it. Asserted here on the object rather than left to LLVM.
# ---------------------------------------------------------------------------
if command -v llvm-nm >/dev/null 2>&1; then
  SYMS="$(llvm-nm "$WORKDIR/rawheap.o" 2>/dev/null)"
  grep -qE '^ *[0-9a-f]+ ' <<<"$SYMS" \
    || fail "llvm-nm listed no symbols for rawheap.o; the checks below conclude from a symbol's PRESENCE and would be inconclusive"
  for sym in dc_heap dc_heap_bump dc_heap_free dc_heap_live dc_heap_sizes; do
    grep -qE "[[:space:]]$sym\$" <<<"$SYMS" \
      || fail "heap global \"$sym\" is missing from an object that allocates — see ADR-0058's needsHeap predicate"
  done
  echo "  heap globals ok: all five emitted for a raw-allocation-only module"
fi

# ---------------------------------------------------------------------------
# Step 2 — BEHAVIOUR. Build for the host, link ordinarily, run.
#
# No Linux/x86-64 gate: this links against real libc like
# examples/demo-collatz does, so it runs natively on macOS, Linux and Windows.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host \
    rawheap.dart -o "$WORKDIR/rawheap_host.o" --emit-header "$WORKDIR/rawheap.h" ) \
    >"$WORKDIR/hostbuild.log" 2>&1 \
  || { cat "$WORKDIR/hostbuild.log" >&2; fail "dcc build --target host failed"; }

[[ -f "$WORKDIR/rawheap.h" ]] || fail "--emit-header produced no header"

clang -I"$WORKDIR" -o "$WORKDIR/rawheap_test" "$EXAMPLE_DIR/main.c" \
  "$WORKDIR/rawheap_host.o" >"$WORKDIR/link.log" 2>&1 \
  || { cat "$WORKDIR/link.log" >&2; fail "hosted link failed"; }

OUT="$("$WORKDIR/rawheap_test")"; STATUS=$?
echo "$OUT"
[[ $STATUS -eq 0 ]] || fail "rodata_test exited $STATUS — a value read back wrong"
grep -q "RAWHEAP: all correct" <<<"$OUT" || fail "unexpected output: $OUT"

echo "RAWHEAP: PASS — a StrBuf grows from capacity 1 to 500,000 bytes across ~19 runtime-sized reallocations, every byte correct, sizes below the smallest class clamp rather than truncate, and dc_heap_live returns to zero after every call"
exit 0
