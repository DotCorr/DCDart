#!/usr/bin/env bash
# core/tests/conformance/m2-compare/run.sh
#
# Mechanical check of docs/decisions/0035-complete-integer-operators.md's
# comparison half: <, <=, >, >= for u8/u16/u32/u64, and == / != (which
# lower through Kernel's EqualsCall, NOT through a prelude operator member
# -- Dart forbids declaring `operator ==` on an extension type, so that is
# a separate recognition path from every other operator in the language).
# Like m2-bitwise and unlike m2-port, these are unprivileged instructions
# -- real execution and an exact expected-value check, the strongest form
# this project's harnesses use.
#
# Usage:
#   bash core/tests/conformance/m2-compare/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-compare"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() {
  echo "M2-COMPARE: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M2-COMPARE: FAIL — $1" >&2
  exit 2
}

[[ -f "$EXAMPLE_DIR/compare.dart" ]] || setup_error "missing target source $EXAMPLE_DIR/compare.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing target harness $EXAMPLE_DIR/main.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-m2-compare.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/compare.o"
BIN="$WORKDIR/compare_test"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare compare.dart -o compare.o
# ---------------------------------------------------------------------------
if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare compare.dart -o "$OBJ" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare compare.dart -o compare.o' exited $DCC_STATUS"
fi
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"

# ---------------------------------------------------------------------------
# Step 2 — verify-freestanding.sh compare.o must report a clean pass.
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
# Step 3 — link main.c against compare.o and produce a runnable binary.
#
# On Linux/x86-64 this is still the freestanding link: -ffreestanding
# -fno-builtin -nostdlib -static, plus a hand-written `_start`, because
# -nostdlib means there is no crt0 and therefore nothing to call `main`.
# That link is belt-and-braces evidence that compare.o needs no crt, no libc
# and no dynamic loader.
#
# On every other host that `_start` cannot work -- it is x86-64 Linux
# `sys_exit` by construction -- so the shared helper rebuilds compare.dart
# for `--target host` and links it against libc instead. See
# tests/conformance/_lib/hosted-link.sh for exactly what that trades away;
# short version: nothing this harness relied on it for, because compare.o's
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
dc_link "$BIN" "$EXAMPLE_DIR/main.c" "$OBJ" "$EXAMPLE_DIR/compare.dart"

# ---------------------------------------------------------------------------
# Step 4 — run the binary, assert exit code 0. main.c's own checks:
# 1-4 = <, <=, >, >= at u64 wrong; 5-8 = same four at u32; 9-12 = at u16;
# 13-16 = at u8; 17-20 = a signed predicate was emitted instead of an
# unsigned one at u64/u32/u16/u8 (0 vs that width's maximum); 21-28 =
# == / != wrong at u64/u32/u16/u8; 29-32 = == / != wrong at each width's
# maximum; 33-34 = == / != with an else-branch; 35 = != as a loop
# condition; 36 = == as a loop condition; 40-41 = clamp at u64/u8;
# 42-43 = three-way compare at u64/u16; 44 = max-of-three at u32;
# 45 = subtractive GCD; 46 = < inside a loop body —
# see core/examples/m2-compare/main.c.
# ---------------------------------------------------------------------------
"$BIN"
ACTUAL=$?
if [[ $ACTUAL -ne 0 ]]; then
  fail "compare_test exited $ACTUAL — see core/examples/m2-compare/main.c for what each code means"
fi

echo "M2-COMPARE: PASS — dcc build -> verify-freestanding pass -> $DC_LINK_MODE link -> real execution, <, <=, >, >= at u64/u32/u16/u8 and == / != at u64/u32/u16/u8 over boundary values (equal, off-by-one each side, 0, and each type's maximum), plus clamp, three-way compare, max-of-three and subtractive GCD, all correct"
exit 0
