#!/usr/bin/env bash
# core/tests/conformance/m2-weak/run.sh
#
# Mechanical check of docs/decisions/0023-weak-references.md: weak
# references (spec §3.3 layer 1) — MakeWeak/WeakLoad/DropWeak, zombie-slot
# semantics, and the "nils out when the target dies" property spec §3.3
# names directly. Mirrors the other M2 conformance harnesses' structure.
#
# Usage:
#   bash core/tests/conformance/m2-weak/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-weak"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() {
  echo "M2-weak: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M2-weak: FAIL — $1" >&2
  exit 2
}

[[ -f "$EXAMPLE_DIR/weak.dart" ]] || setup_error "missing target source $EXAMPLE_DIR/weak.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing target harness $EXAMPLE_DIR/main.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-m2-weak.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/weak.o"
BIN="$WORKDIR/weak_test"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare weak.dart -o weak.o
# ---------------------------------------------------------------------------
if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare weak.dart -o "$OBJ" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare weak.dart -o weak.o' exited $DCC_STATUS"
fi
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"

# ---------------------------------------------------------------------------
# Step 2 — verify-freestanding.sh weak.o must report a clean pass.
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
# Step 3 — link main.c against weak.o and run it.
#
# The link itself is delegated to the shared helper in
# tests/conformance/_lib/hosted-link.sh, which picks a link path per host.
# On Linux/x86-64 it still performs the freestanding link -- `-ffreestanding
# -fno-builtin -nostdlib -static` plus a hand-written `_start`, since with
# `-nostdlib` there is no crt0 to call `main` -- and so keeps the
# belt-and-braces link-level evidence that weak.o needs no crt, no libc and
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
dc_link "$BIN" "$EXAMPLE_DIR/main.c" "$OBJ" "$EXAMPLE_DIR/weak.dart"

# ---------------------------------------------------------------------------
# Step 4 — run the binary, assert exit code 0. main.c's own checks: 1 = not
# at baseline before any call, 2/4 = zombie-slot mechanics wrong, 3 = weak
# didn't nil out, 5/6/8 = alive-path mechanics wrong, 7 = value wrong — see
# core/examples/m2-weak/main.c.
# ---------------------------------------------------------------------------
"$BIN"
ACTUAL=$?
if [[ $ACTUAL -ne 0 ]]; then
  fail "weak_test exited $ACTUAL — see core/examples/m2-weak/main.c for what each code means"
fi

echo "M2-weak: PASS — dcc build -> verify-freestanding pass -> $DC_LINK_MODE link -> 1000 real weak-reference cycles (dangling + alive paths), zombie-slot mechanics exact, genuinely leak-free"
exit 0
