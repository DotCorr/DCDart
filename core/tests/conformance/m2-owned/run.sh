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
# Step 3 — link main.c against owned.o, freestanding. Same Linux/x86-64-only
# entry stub as the other conformance harnesses (GAP-0005).
# ---------------------------------------------------------------------------
if ! command -v clang >/dev/null 2>&1; then
  fail "clang not found on PATH, see docs/known-gaps.md GAP-0001"
fi

HOST_OS="$(uname -s 2>/dev/null || echo unknown)"
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
case "$HOST_OS" in
  Linux*) ;;
  *) fail "this harness's freestanding entry stub is Linux/x86-64 only (host reported '$HOST_OS'); see docs/known-gaps.md GAP-0005" ;;
esac
case "$HOST_ARCH" in
  x86_64|amd64) ;;
  *) fail "this harness's freestanding entry stub is Linux/x86-64 only (host reported '$HOST_ARCH'); see docs/known-gaps.md GAP-0005" ;;
esac

cat > "$WORKDIR/_start.S" <<'EOF'
    .text
    .global _start
_start:
    call    main
    movl    %eax, %edi
    movl    $60, %eax
    syscall
EOF

LINK_LOG="$WORKDIR/link.log"
clang -ffreestanding -fno-builtin -nostdlib -static \
  -o "$BIN" "$WORKDIR/_start.S" "$EXAMPLE_DIR/main.c" "$OBJ" \
  >"$LINK_LOG" 2>&1
LINK_STATUS=$?
if [[ $LINK_STATUS -ne 0 ]]; then
  cat "$LINK_LOG" >&2
  fail "freestanding link of main.c + owned.o exited $LINK_STATUS (log above)"
fi
[[ -f "$BIN" ]] || fail "clang reported success but $BIN was not produced"

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

echo "M2-owned: PASS — dcc build -> verify-freestanding pass -> freestanding link -> 1000 real construct/transfer/consume cycles (both C-driven and DCDart-driven), genuinely leak-free, unbounded"
exit 0
