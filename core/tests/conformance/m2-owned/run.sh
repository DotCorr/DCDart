#!/usr/bin/env bash
# core/tests/conformance/m2-owned/run.sh
#
# Mechanical check of docs/decisions/0021-owned-parameters.md: @owned
# parameters, the consuming counterpart to ADR-0019's borrowed-by-default
# convention (spec §3.2 item 2). Mirrors the other M2 conformance
# harnesses' structure. Unlike m2-heap-param/m2-heap-field, THIS one runs
# unbounded (well past the 64-slot arena) and asserts genuine leak-free
# behavior throughout, since @owned finally provides a real release
# mechanism for a reference the releasing function did not itself
# construct.
#
# Usage:
#   bash core/tests/conformance/m2-owned/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-owned"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() {
  echo "M2-owned: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M2-owned: FAIL — $1" >&2
  exit 2
}

[[ -f "$EXAMPLE_DIR/owned.dart" ]] || setup_error "missing target source $EXAMPLE_DIR/owned.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing target harness $EXAMPLE_DIR/main.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-m2-owned.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/owned.o"
BIN="$WORKDIR/owned_test"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare owned.dart -o owned.o
# ---------------------------------------------------------------------------
if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare owned.dart -o "$OBJ" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare owned.dart -o owned.o' exited $DCC_STATUS"
fi
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"

# ---------------------------------------------------------------------------
# Step 2 — verify-freestanding.sh owned.o must report a clean pass.
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
# Step 3 — link main.c against owned.o and run it.
#
# The link itself is delegated to the shared helper in
# tests/conformance/_lib/hosted-link.sh, which picks a link path per host.
# On Linux/x86-64 it still performs the freestanding link -- `-ffreestanding
# -fno-builtin -nostdlib -static` plus a hand-written `_start`, since with
# `-nostdlib` there is no crt0 to call `main` -- and so keeps the
# belt-and-braces link-level evidence that owned.o needs no crt, no libc and
# no dynamic loader. On every other host the helper rebuilds the source for
# `--target host` and links against libc, because the bare-x86_64 object is
# ELF and will not link into a Mach-O or PE image.
#
# What the hosted path gives up is only that link-level evidence, not the
# freestanding guarantee itself: Step 2 above asserts it directly on the
# bare-x86_64 object via verify-freestanding.sh, which runs identically on
# all three hosts and is the stronger of the two checks. See the helper's
# header for the full reasoning.
#
# This is GAP-0048 closed. This harness previously FAILED rather than
# skipped on macOS and Windows, so it could not run on two of the three
# hosts DCDart claims to support. $DC_LINK_MODE, set by dc_link, records
# which path actually ran and is reported in the PASS line below, so a pass
# is never ambiguous about what it proved.
# ---------------------------------------------------------------------------
source "$CORE_DIR/tests/conformance/_lib/hosted-link.sh"
dc_link "$BIN" "$EXAMPLE_DIR/main.c" "$OBJ" "$EXAMPLE_DIR/owned.dart"

# ---------------------------------------------------------------------------
# Step 4 — run the binary, assert exit code 0. main.c's own checks: 1 = not
# at baseline before any call, 2/3 = direct C-driven construct+consume
# wrong, 4/5 = DCDart-side wrapper (retain-on-transfer) wrong — see
# core/examples/m2-owned/main.c.
# ---------------------------------------------------------------------------
"$BIN"
ACTUAL=$?
if [[ $ACTUAL -ne 0 ]]; then
  fail "owned_test exited $ACTUAL — see core/examples/m2-owned/main.c for what each code means"
fi

echo "M2-owned: PASS — dcc build -> verify-freestanding pass -> $DC_LINK_MODE link -> 1000 real construct/transfer/consume cycles (both C-driven and DCDart-driven), genuinely leak-free, unbounded"
exit 0
