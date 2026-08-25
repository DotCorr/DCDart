#!/usr/bin/env bash
# core/tests/conformance/m0/run.sh
#
# Mechanical check of the M0 exit criterion (ROADMAP.md, verbatim):
#
#   `dcc build --mode bare add.dart -o add.o` produces an object file where
#   `nm -u add.o` prints nothing. A C `main` links against it and returns 5
#   for `add(2,3)`.
#
# This script does NOT stub, skip, or fake success. Per CLAUDE.md / SKILL.md,
# a stubbed pass is worse than an honest failure. When a prerequisite is
# missing, or step 3's link stub can't run on the current host (Linux/
# x86-64 only, see below), this script prints a specific "M0: FAIL — ..."
# line and exits nonzero. It never silently skips a step and never reports
# PASS without having actually run every step below.
#
# As of 2026-08-13, steps 1-2 (dcc build, verify-freestanding) pass for real
# on this project's dev host (Windows). Step 3 (link+run) correctly refuses
# to run there -- see its own comment below and docs/known-gaps.md GAP-0048.
# This script has not yet reported an unqualified PASS anywhere; that needs
# a Linux host or QEMU.
#
# Usage:
#   bash core/tests/conformance/m0/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail
# Deliberately NOT `set -e`: every step below is checked explicitly so this
# script can print a specific, attributable failure message instead of dying
# on whichever line happened to trip `errexit`.

# ---------------------------------------------------------------------------
# Paths (all resolved relative to this script, so it can be invoked from
# anywhere: `bash core/tests/conformance/m0/run.sh`, `./run.sh`, CI, etc.)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m0-seam"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() {
  echo "M0: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M0: FAIL — $1" >&2
  exit 2
}

[[ -f "$EXAMPLE_DIR/add.dart" ]] || setup_error "missing target source $EXAMPLE_DIR/add.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing target harness $EXAMPLE_DIR/main.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-m0.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/add.o"
BIN="$WORKDIR/add_test"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare add.dart -o add.o
# (paths relative to the m0-seam example dir, per the exit criterion)
# ---------------------------------------------------------------------------
# `dcc` is not (yet) a standalone binary on PATH -- it's `dart
# core/dcc/bin/dcc.dart` (see core/dcc/README.md; a real installed launcher
# script is future packaging work, not built yet). Prefer an actual `dcc` on
# PATH if one exists (future-proof once that packaging exists); fall back to
# invoking it through `dart` otherwise, which is what actually exists today.
if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare add.dart -o "$OBJ" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare add.dart -o add.o' exited $DCC_STATUS"
fi
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"

# ---------------------------------------------------------------------------
# Step 2 — verify-freestanding.sh add.o must report a clean pass.
# ---------------------------------------------------------------------------
if ! command -v llvm-nm >/dev/null 2>&1; then
  fail "llvm-nm not found on PATH (required by verify-freestanding.sh), see docs/known-gaps.md GAP-0001"
fi
[[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST (owned by E4, see core/tools/bare-symbol-allowlist.txt)"

VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$OBJ" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
if [[ $VERIFY_STATUS -ne 0 ]] || ! grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass for $OBJ"
fi

# ---------------------------------------------------------------------------
# Step 3 — link main.c against add.o, freestanding (no libc, no default
# startup files).
#
# Flag reasoning:
#   -ffreestanding  : tells clang not to assume a hosted environment (no
#                     libc semantics for standard function names, no
#                     assumption that `main` is called with a normal CRT).
#   -fno-builtin    : stop clang from silently substituting libc builtins
#                     (memcpy/memset/etc.) for patterns it recognizes in
#                     main.c or add.o's surrounding code -- those calls
#                     would show up as undefined symbols at link time, or
#                     worse, link in libc if it's on the system.
#   -nostdlib       : do not link libc and do not link the default CRT
#                     startup objects (crt0/crt1). This is the actual
#                     "freestanding link" -- without it, a normal `cc main.c
#                     add.o -o add_test` would silently pull in glibc/musl
#                     and prove nothing about add.o's freestanding-ness.
#   -static         : avoid producing a dynamically-linked binary (which
#                     would need a PT_INTERP dynamic loader) -- irrelevant
#                     without libc, but keeps the output a plain static ELF.
#
# The catch with -nostdlib: there is no crt0, so there is no `_start` to call
# `main`. The shared helper supplies one on Linux/x86-64, and on every other
# host links against libc instead -- see tests/conformance/_lib/hosted-link.sh
# for exactly what that trades away (short version: nothing that this harness
# was relying on it for, because add.o's freestanding guarantee is asserted in
# Step 2 above by verify-freestanding.sh, which runs on every host and is the
# stronger check of the two).
#
# This is GAP-0048 closed: the harness used to FAIL rather than skip on macOS
# and Windows, so 17 of these targets could not run on two of the three hosts
# DCDart claims to support.
# ---------------------------------------------------------------------------
source "$CORE_DIR/tests/conformance/_lib/hosted-link.sh"
dc_link "$BIN" "$EXAMPLE_DIR/main.c" "$OBJ" "$EXAMPLE_DIR/add.dart"

# ---------------------------------------------------------------------------
# Step 4 — run the binary, assert exit code is exactly 5.
# ---------------------------------------------------------------------------
"$BIN"
ACTUAL=$?
if [[ $ACTUAL -ne 5 ]]; then
  fail "add_test exited $ACTUAL, expected 5 (add(2,3) must equal 5)"
fi

# ---------------------------------------------------------------------------
# Step 5 — PASS.
# ---------------------------------------------------------------------------
echo "M0: PASS — dcc build -> verify-freestanding pass -> $DC_LINK_MODE link -> add(2,3) == 5"
exit 0
