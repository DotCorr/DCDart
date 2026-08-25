#!/usr/bin/env bash
# core/tests/conformance/m2-bitwise/run.sh
#
# Mechanical check of docs/decisions/0030-bitwise-operators.md: &, |, ^,
# <<, >> for u8/u16/u32/u64. Unlike m2-port, these are unprivileged
# instructions -- real execution and an exact expected-value check, the
# strongest form this project's harnesses use.
#
# Usage:
#   bash core/tests/conformance/m2-bitwise/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-bitwise"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() {
  echo "M2-bitwise: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M2-bitwise: FAIL — $1" >&2
  exit 2
}

[[ -f "$EXAMPLE_DIR/bitwise.dart" ]] || setup_error "missing target source $EXAMPLE_DIR/bitwise.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing target harness $EXAMPLE_DIR/main.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-m2-bitwise.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/bitwise.o"
BIN="$WORKDIR/bitwise_test"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare bitwise.dart -o bitwise.o
# ---------------------------------------------------------------------------
if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare bitwise.dart -o "$OBJ" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare bitwise.dart -o bitwise.o' exited $DCC_STATUS"
fi
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"

# ---------------------------------------------------------------------------
# Step 2 — verify-freestanding.sh bitwise.o must report a clean pass.
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
# Step 3 — link main.c against bitwise.o and produce a runnable binary.
#
# On Linux/x86-64 this is still the freestanding link: -ffreestanding
# -fno-builtin -nostdlib -static, plus a hand-written `_start`, because
# -nostdlib means there is no crt0 and therefore nothing to call `main`.
# That link is belt-and-braces evidence that bitwise.o needs no crt, no libc
# and no dynamic loader.
#
# On every other host that `_start` cannot work -- it is x86-64 Linux
# `sys_exit` by construction -- so the shared helper rebuilds bitwise.dart
# for `--target host` and links it against libc instead. See
# tests/conformance/_lib/hosted-link.sh for exactly what that trades away;
# short version: nothing this harness relied on it for, because bitwise.o's
# freestanding guarantee is asserted in Step 2 above by
# verify-freestanding.sh, which runs identically on every host and is the
# stronger of the two checks.
#
# This is GAP-0048 closed: this harness used to FAIL rather than skip on
# macOS and Windows, so it (and 16 sibling targets) could not run on two of
# the three hosts DCDart claims to support. $DC_LINK_MODE records which path
# ran and is printed in the PASS line, so a pass is never ambiguous about
# what it proved.
# ---------------------------------------------------------------------------
source "$CORE_DIR/tests/conformance/_lib/hosted-link.sh"
dc_link "$BIN" "$EXAMPLE_DIR/main.c" "$OBJ" "$EXAMPLE_DIR/bitwise.dart"

# ---------------------------------------------------------------------------
# Step 4 — run the binary, assert exit code 0. main.c's own checks: 1-3 =
# and/or/xor at u64 wrong, 4-5 = shl/shr at u64 wrong, 6-8 = and at
# u32/u16/u8 wrong — see core/examples/m2-bitwise/main.c.
# ---------------------------------------------------------------------------
"$BIN"
ACTUAL=$?
if [[ $ACTUAL -ne 0 ]]; then
  fail "bitwise_test exited $ACTUAL — see core/examples/m2-bitwise/main.c for what each code means"
fi

echo "M2-bitwise: PASS — dcc build -> verify-freestanding pass -> $DC_LINK_MODE link -> real execution, &, |, ^, << (u64) exhaustive over ranges, >> (u64) over ranges, & at u32/u16/u8, all correct"
exit 0
