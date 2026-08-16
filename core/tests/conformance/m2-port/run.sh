#!/usr/bin/env bash
# core/tests/conformance/m2-port/run.sh
#
# Mechanical check of docs/decisions/0029-port-io.md: x86 port I/O
# (`Port.outb`/`Port.inb`, PortOut/PortIn DC-IR instructions). Unlike every
# other conformance harness in this project, this one does NOT execute the
# compiled binary -- `outb`/`inb` are privileged (ring-0-only) instructions
# that trap (SIGSEGV) in a normal Linux userspace process. Instead this
# verifies the real, full pipeline (front_end -> dcc-lower -> DC-IR ->
# backend -> clang) produced the CORRECT machine code, via disassembly.
# The real execute-and-prove-it-works test happens in oscortex_core's own
# kernel, which runs as actual ring-0 code under full-system QEMU emulation.
#
# Usage:
#   bash core/tests/conformance/m2-port/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-port"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() {
  echo "M2-port: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "M2-port: FAIL — $1" >&2
  exit 2
}

[[ -f "$EXAMPLE_DIR/port_io.dart" ]] || setup_error "missing target source $EXAMPLE_DIR/port_io.dart"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-m2-port.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/port_io.o"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare port_io.dart -o port_io.o
# ---------------------------------------------------------------------------
if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare port_io.dart -o "$OBJ" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare port_io.dart -o port_io.o' exited $DCC_STATUS"
fi
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"

# ---------------------------------------------------------------------------
# Step 2 — verify-freestanding.sh port_io.o must report a clean pass. Real
# port I/O codegen is inline asm, not a call to any symbol, so this also
# confirms the new instructions didn't accidentally introduce a runtime
# dependency.
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
# Step 3 — disassemble and assert the exact real x86 instructions appear.
# initCom1() has 7 Port.outb calls, readLineStatus() has 1 Port.inb call —
# see core/examples/m2-port/port_io.dart for what each one does.
# ---------------------------------------------------------------------------
if ! command -v llvm-objdump >/dev/null 2>&1; then
  fail "llvm-objdump not found on PATH, see docs/known-gaps.md GAP-0001"
fi

DISASM="$(llvm-objdump -d "$OBJ")"
OUTB_COUNT="$(grep -c $'\t''outb'$'\t' <<<"$DISASM" || true)"
INB_COUNT="$(grep -c $'\t''inb'$'\t' <<<"$DISASM" || true)"

if [[ "$OUTB_COUNT" -ne 7 ]]; then
  echo "$DISASM" >&2
  fail "expected 7 'outb' instructions in the disassembly, found $OUTB_COUNT"
fi
if [[ "$INB_COUNT" -ne 1 ]]; then
  echo "$DISASM" >&2
  fail "expected 1 'inb' instruction in the disassembly, found $INB_COUNT"
fi

echo "M2-port: PASS — dcc build -> verify-freestanding pass -> disassembly confirms 7 real outb + 1 real inb instruction, correct opcodes, not executed (privileged instructions, see docs/decisions/0029-port-io.md)"
exit 0
