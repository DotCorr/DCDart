#!/usr/bin/env bash
# core/tests/conformance/m2-heap-field/run.sh
#
# Mechanical check of docs/decisions/0020-heap-typed-fields.md (a HeapObject
# subclass holding a reference to another HeapObject) composed with
# docs/decisions/0022-destructor-cascade.md (the destructor that actually
# releases that field when the parent dies). Originally asserted a
# deliberate, bounded, non-zero leak rate before ADR-0022 existed; now
# asserts genuine UNBOUNDED leak-freedom — see main.c for the full history.
#
# Usage:
#   bash core/tests/conformance/m2-heap-field/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-heap-field"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() {
  echo "M2-heap-field: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M2-heap-field: FAIL — $1" >&2
  exit 2
}

[[ -f "$EXAMPLE_DIR/heap_field.dart" ]] || setup_error "missing target source $EXAMPLE_DIR/heap_field.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing target harness $EXAMPLE_DIR/main.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-m2-heap-field.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/heap_field.o"
BIN="$WORKDIR/heap_field_test"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare heap_field.dart -o heap_field.o
# ---------------------------------------------------------------------------
if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare heap_field.dart -o "$OBJ" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare heap_field.dart -o heap_field.o' exited $DCC_STATUS"
fi
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"

# ---------------------------------------------------------------------------
# Step 2 — verify-freestanding.sh heap_field.o must report a clean pass.
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
# Step 3 — link main.c against heap_field.o, freestanding. Same Linux/
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
  fail "freestanding link of main.c + heap_field.o exited $LINK_STATUS (log above)"
fi
[[ -f "$BIN" ]] || fail "clang reported success but $BIN was not produced"

# ---------------------------------------------------------------------------
# Step 4 — run the binary, assert exit code 0. main.c's own checks: 1 = not
# at baseline before any call, 2 = nested construction/read wrong, 3 =
# leaked (destructor under-released) or double-freed (over-released) — see
# core/examples/m2-heap-field/main.c.
# ---------------------------------------------------------------------------
"$BIN"
ACTUAL=$?
if [[ $ACTUAL -ne 0 ]]; then
  fail "heap_field_test exited $ACTUAL — see core/examples/m2-heap-field/main.c for what each code means"
fi

echo "M2-heap-field: PASS — dcc build -> verify-freestanding pass -> freestanding link -> 1000 nested-construct/read/destructor-cascade cycles, genuinely leak-free and unbounded"
exit 0
