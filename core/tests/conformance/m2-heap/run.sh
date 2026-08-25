#!/usr/bin/env bash
# core/tests/conformance/m2-heap/run.sh
#
# Mechanical check of M2's first exit-criterion slice (ROADMAP.md):
# "allocation-heavy programs run leak-free under dc-test --leakcheck."
# Mirrors core/tests/conformance/m0/run.sh's structure and honesty rules.
#
# This is NOT all of M2 -- no weak/unowned, no elision, no cycle handling,
# no ClassInfo/destructors (docs/known-gaps.md GAP-0003, still open). It's
# the first real, verified slice: allocate a heap object, read a field,
# release it correctly, 1000 times, checked for leaks every time.
#
# Usage:
#   bash core/tests/conformance/m2-heap/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-heap"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() {
  echo "M2-heap: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M2-heap: FAIL — $1" >&2
  exit 2
}

[[ -f "$EXAMPLE_DIR/box.dart" ]] || setup_error "missing target source $EXAMPLE_DIR/box.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing target harness $EXAMPLE_DIR/main.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-m2-heap.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/box.o"
BIN="$WORKDIR/box_test"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare box.dart -o box.o
# ---------------------------------------------------------------------------
if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare box.dart -o "$OBJ" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare box.dart -o box.o' exited $DCC_STATUS"
fi
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"

# ---------------------------------------------------------------------------
# Step 2 — verify-freestanding.sh box.o must report a clean pass.
# ---------------------------------------------------------------------------
if ! command -v llvm-nm >/dev/null 2>&1; then
  fail "llvm-nm not found on PATH (required by verify-freestanding.sh), see docs/known-gaps.md GAP-0001"
fi
[[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"

VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$OBJ" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
if [[ $VERIFY_STATUS -ne 0 ]] || ! grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass for $OBJ"
fi

# ---------------------------------------------------------------------------
# Step 3 — link main.c against box.o and run it.
#
# The link is freestanding where that is possible: -nostdlib (no libc, no CRT
# startup objects) plus -ffreestanding -fno-builtin, so nothing can silently
# pull glibc/musl in and prove nothing about box.o's freestanding-ness. The
# catch with -nostdlib is that there is no crt0, so there is no `_start` to
# call `main`; the entry stub that supplies one issues the x86-64 *Linux*
# sys_exit syscall and is Linux/x86-64 by construction.
#
# That stub used to gate this whole harness: on a macOS or Windows host this
# step did not skip, it FAILED. So the shared helper below now decides. On
# Linux/x86-64 it takes exactly the -nostdlib path described above and keeps
# the belt-and-braces link evidence; on every other host it rebuilds the
# source for --target host and links against real libc, keeping the
# behavioural assertion. See tests/conformance/_lib/hosted-link.sh for
# precisely what the hosted path trades away -- short version: nothing this
# harness was relying on it for, because box.o's freestanding guarantee is
# asserted in Step 2 above by verify-freestanding.sh, which runs identically
# on every host and is the stronger check of the two.
#
# This is GAP-0048 closed. $DC_LINK_MODE records which path ran, and the PASS
# line below prints it, so a pass is never ambiguous about what it proved.
# ---------------------------------------------------------------------------
source "$CORE_DIR/tests/conformance/_lib/hosted-link.sh"
dc_link "$BIN" "$EXAMPLE_DIR/main.c" "$OBJ" "$EXAMPLE_DIR/box.dart"

# ---------------------------------------------------------------------------
# Step 4 — run the binary, assert exit code 0. main.c's own checks: 1 = not
# at baseline before any call, 2 = field construction/read wrong, 3 = leaked
# (or double-freed) — see core/examples/m2-heap/main.c.
# ---------------------------------------------------------------------------
"$BIN"
ACTUAL=$?
if [[ $ACTUAL -ne 0 ]]; then
  fail "box_test exited $ACTUAL — see core/examples/m2-heap/main.c for what each code means"
fi

echo "M2-heap: PASS — dcc build -> verify-freestanding pass -> $DC_LINK_MODE link -> 1000 alloc/read/release cycles, leak-free"
exit 0
