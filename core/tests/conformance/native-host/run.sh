#!/usr/bin/env bash
# core/tests/conformance/native-host/run.sh
#
# The native-host conformance target. Every other harness in this directory
# links its @bare object with `-ffreestanding -nostdlib -static` plus a
# hand-written `_start.S`, and gates itself to Linux/x86-64 because that stub
# is Linux/x86-64-only (former GAP-0048). It had to: dcc hardcoded the
# freestanding triple `x86_64-unknown-none-elf`, so its output was not a
# native object for any real host OS.
#
# `dcc build --mode bare --target host` emits a native object for the machine
# running the build -- Mach-O on macOS, COFF on Windows, ELF on Linux. This
# harness is the mechanical proof: it links with PLAIN clang (no
# -ffreestanding, no -nostdlib, no -static, no entry stub) into an ordinary
# hosted C program with real libc and real printf, and runs it. THE ABSENCE
# OF A HOST GATE IS THE FEATURE UNDER TEST -- this harness is meant to run on
# macOS, Linux and Windows alike, so do not add one back.
#
# It also still requires the object to be FREESTANDING-CLEAN: targeting a
# native OS must not drag in a single libc symbol. A native target that
# needed libc would be a regression, not a feature.
#
# Usage:
#   bash core/tests/conformance/native-host/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/native-host"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() {
  echo "NATIVE-HOST: FAIL -- $1" >&2
  exit 1
}

setup_error() {
  echo "NATIVE-HOST: FAIL -- $1" >&2
  exit 2
}

[[ -f "$EXAMPLE_DIR/native.dart" ]] || setup_error "missing target source $EXAMPLE_DIR/native.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing target harness $EXAMPLE_DIR/main.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-native-host.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/native.o"
HDR="$WORKDIR/native.h"
BIN="$WORKDIR/native_host_test"
RUN_LOG="$WORKDIR/run.log"

HOST_OS="$(uname -s 2>/dev/null || echo unknown)"
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
echo "host: $HOST_OS/$HOST_ARCH (no gate -- this harness must pass on every host)"

# ---------------------------------------------------------------------------
# Step 1 -- dcc build --mode bare --target host native.dart -o native.o
# ---------------------------------------------------------------------------
if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host native.dart -o "$OBJ" --emit-header "$HDR" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare --target host native.dart -o native.o' exited $DCC_STATUS"
fi
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"
[[ -s "$OBJ" ]] || fail "dcc produced an empty $OBJ"

if command -v file >/dev/null 2>&1; then
  echo "object: $(file -b "$OBJ")"
fi

# ---------------------------------------------------------------------------
# Step 2 -- verify-freestanding.sh must STILL report a clean pass. A native
# target must not drag in libc: `--target host` changes the object format and
# triple, nothing about @bare's no-runtime contract. verify-freestanding.sh
# already normalizes Mach-O's leading-underscore symbol prefix, so this is a
# real check on macOS, not a vacuous one.
# ---------------------------------------------------------------------------
if ! command -v llvm-nm >/dev/null 2>&1; then
  fail "llvm-nm not found on PATH (required by verify-freestanding.sh), see docs/known-gaps.md GAP-0001"
fi
[[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"

VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$OBJ" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
if [[ $VERIFY_STATUS -ne 0 ]] || ! grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass for the --target host object $OBJ"
fi

# ---------------------------------------------------------------------------
# Step 3 -- link with PLAIN clang. No -nostdlib, no -static, no
# -ffreestanding, no _start.S. Just `clang -o BIN main.c native.o`, the way
# any ordinary C project would consume a third-party object file. If this
# step ever needs a flag added to make it work, the feature is not done.
# ---------------------------------------------------------------------------
if ! command -v clang >/dev/null 2>&1; then
  fail "clang not found on PATH, see docs/known-gaps.md GAP-0001"
fi

LINK_LOG="$WORKDIR/link.log"
echo "link: clang -o \$BIN $EXAMPLE_DIR/main.c \$OBJ"
clang -o "$BIN" "$EXAMPLE_DIR/main.c" "$OBJ" >"$LINK_LOG" 2>&1
LINK_STATUS=$?
if [[ $LINK_STATUS -ne 0 ]]; then
  cat "$LINK_LOG" >&2
  fail "plain 'clang -o BIN main.c native.o' exited $LINK_STATUS on $HOST_OS/$HOST_ARCH (log above) -- a --target host object must link with no freestanding flags"
fi
[[ -x "$BIN" ]] || fail "clang reported success but $BIN was not produced"

# ---------------------------------------------------------------------------
# Step 4 -- run the native binary. Exit code 0, and stdout must contain the
# independently-known values (perfect numbers below 10000; pi(10000); the
# ARC arena back at its 64-slot baseline). Checking stdout as well as the
# exit code means a main() that silently returned 0 without doing the work
# cannot pass this.
# ---------------------------------------------------------------------------
"$BIN" >"$RUN_LOG" 2>&1
RUN_STATUS=$?
cat "$RUN_LOG"
if [[ $RUN_STATUS -ne 0 ]]; then
  fail "native_host_test exited $RUN_STATUS -- see core/examples/native-host/main.c for what each exit code means"
fi

EXPECTED_LINES=(
  "perfectCount(2, 10000)             = 4"
  "perfectSum(2, 10000)               = 8658"
  "primeCount(10000)                  = 1229"
  "primeSum(10000)                    = 5736396"
  "sumOfSquares(1000)                 = 333833500"
  "gcd(1071, 462)                     = 21"
  "lcm(1071, 462)                     = 23562"
  "digitSum(9876543210)               = 45"
  "modPow32(3, 100, 65521)            = 23072"
  "triangleU16(300)                   = 44850"
  "gcdU8(252, 105)                    = 21"
  "sumOfSquares matches the closed form for every n in 0..200"
  "2000 further allocating calls, arena at baseline every time"
  "ARC arena after all calls: dc_free_top = 64 (baseline 64)"
  "ALL CHECKS PASSED"
)
for line in "${EXPECTED_LINES[@]}"; do
  grep -qF -- "$line" "$RUN_LOG" || fail "binary exited 0 but its stdout is missing the expected line: '$line'"
done
if grep -q "FAIL" "$RUN_LOG"; then
  fail "binary exited 0 but its stdout reported a FAIL line"
fi

# The emitted C header is the other half of "consumable from ordinary C".
if [[ -f "$HDR" ]]; then
  for fn in perfectCount primeCount sumOfSquares digitSum modPow32 triangleU16 gcdU8; do
    grep -q "$fn" "$HDR" || fail "--emit-header produced $HDR without a declaration for $fn"
  done
  echo "header: $HDR declares every exported function"
else
  fail "--emit-header was passed but no header was written to $HDR"
fi

# ---------------------------------------------------------------------------
# Step 5 -- PASS.
# ---------------------------------------------------------------------------
echo "NATIVE-HOST: PASS -- dcc build --mode bare --target host on $HOST_OS/$HOST_ARCH -> freestanding-clean native object -> plain 'clang -o bin main.c native.o' (no -nostdlib, no -ffreestanding, no _start stub, no host gate) -> real execution with libc: perfect numbers below 10000 = {6,28,496,8128}, pi(10000) = 1229, sum-of-squares matches n(n+1)(2n+1)/6 over 0..200, gcd/lcm/digitSum/modPow32/triangleU16/gcdU8 correct at u64/u32/u16/u8, ARC arena back at its 64-slot baseline after 2000+ allocating calls"
exit 0
