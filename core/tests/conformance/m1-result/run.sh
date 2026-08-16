#!/usr/bin/env bash
# core/tests/conformance/m1-result/run.sh
#
# Mechanical check of M1's third exit-criterion clause (ROADMAP.md):
# "returns Result<u64, Err> through ? propagation." Mirrors
# core/tests/conformance/m0/run.sh's structure and honesty rules.
#
# RESOLVED (docs/known-gaps.md GAP-0007): this script previously stopped
# after the freestanding check, refusing to link+run because a struct-by-
# value-return ABI question was unverified. Verified under real Linux/WSL:
# the SysV ABI returns this project's {tag,payload} Result representation
# correctly in two registers, matching what core/backend already emits --
# no backend change was needed. The earlier "mismatch" was specific to this
# repo's Windows dev host (a different ABI @bare code was never targeting
# anyway), not a real bug. Full link+run now proceeds like every other
# conformance target.
#
# Usage:
#   bash core/tests/conformance/m1-result/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m1-result"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() {
  echo "M1-result: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M1-result: FAIL — $1" >&2
  exit 2
}

[[ -f "$EXAMPLE_DIR/result_demo.dart" ]] || setup_error "missing target source $EXAMPLE_DIR/result_demo.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing target harness $EXAMPLE_DIR/main.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-m1-result.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/result_demo.o"
BIN="$WORKDIR/result_test"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare result_demo.dart -o result_demo.o
# ---------------------------------------------------------------------------
if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare result_demo.dart -o "$OBJ" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare result_demo.dart -o result_demo.o' exited $DCC_STATUS"
fi
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"

# ---------------------------------------------------------------------------
# Step 2 — verify-freestanding.sh result_demo.o must report a clean pass.
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
# Step 3 — link main.c against result_demo.o, freestanding. Same Linux/
# x86-64-only entry stub as the other conformance harnesses (GAP-0005).
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
  fail "freestanding link of main.c + result_demo.o exited $LINK_STATUS (log above)"
fi
[[ -f "$BIN" ]] || fail "clang reported success but $BIN was not produced"

# ---------------------------------------------------------------------------
# Step 4 — run the binary, assert exit code 0. main.c's own checks: 1-4 name
# exactly which Result value mismatched — see core/examples/m1-result/main.c.
# ---------------------------------------------------------------------------
"$BIN"
ACTUAL=$?
if [[ $ACTUAL -ne 0 ]]; then
  fail "result_test exited $ACTUAL — see core/examples/m1-result/main.c for what each code means"
fi

echo "M1-result: PASS — dcc build -> verify-freestanding pass -> freestanding link -> Result construction/if/.propagate() all correct"
exit 0
