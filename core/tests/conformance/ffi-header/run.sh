#!/usr/bin/env bash
# core/tests/conformance/ffi-header/run.sh
#
# Mechanical check of docs/decisions/0034-c-header-emission.md: `dcc build
# ... --emit-header PATH.h` writes a C header declaring every exported
# function, derived from the same DC-IR the object file is emitted from, and
# a C caller that includes ONLY that header links and runs correctly against
# the object.
#
# WHAT THIS PROVES THAT THE OTHER TARGETS DO NOT
#
# Every other example in this repo (m1-result, m2-bitwise, demo-collatz)
# hand-writes its `extern` prototypes in main.c. Those tests prove the
# object file speaks the C ABI; none of them proves the COMPILER can say so.
# A hand-written prototype that disagrees with the real ABI is not a compile
# error, it is silent corruption at the call boundary -- which is exactly
# what had to be chased down by hand in known-gaps.md GAP-0007. So
# core/examples/ffi-header/main.c declares nothing itself: step 2 below
# fails the run if it ever grows an `extern` line, because at that moment
# the test would stop testing the header emitter and start testing the same
# thing m2-bitwise already covers.
#
# The header is written to a fresh temp dir on every run and main.c is
# compiled with -I pointing there. There is deliberately no checked-in copy
# of ffi.h, so a stale artifact cannot mask a regression in the emitter.
#
# Runs natively on this host -- no QEMU, no Linux/x86-64 gate. Step 3 links
# with plain hosted clang (no -nostdlib): the point here is a normal C
# program calling into DCDart, which is the actual FFI use case, not the
# freestanding kernel link that m2-bitwise checks.
#
# Usage:
#   bash core/tests/conformance/ffi-header/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/ffi-header"

fail() {
  echo "FFI-HEADER: FAIL -- $1" >&2
  exit 1
}

setup_error() {
  echo "FFI-HEADER: FAIL -- $1" >&2
  exit 2
}

[[ -f "$EXAMPLE_DIR/ffi.dart" ]] || setup_error "missing target source $EXAMPLE_DIR/ffi.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing target harness $EXAMPLE_DIR/main.c"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-ffi-header.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/ffi.o"
HDR="$WORKDIR/ffi.h"
BIN="$WORKDIR/ffi_test"

# ---------------------------------------------------------------------------
# Step 1 -- dcc build --mode bare --target host ffi.dart -o ffi.o
#           --emit-header $WORKDIR/ffi.h
#
# --target host so the object matches whatever machine this is running on
# and can be linked by the native clang in step 3 (backend/lib/targets.dart,
# ADR-0033). --mode bare is unchanged: header emission is orthogonal to the
# mode, it reads the DCModule the object was emitted from.
# ---------------------------------------------------------------------------
if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host ffi.dart -o "$OBJ" --emit-header "$HDR" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare --target host ffi.dart -o ffi.o --emit-header ffi.h' exited $DCC_STATUS"
fi
[[ -f "$OBJ" ]] || fail "dcc reported success but the object file $OBJ was not produced"

# ---------------------------------------------------------------------------
# Step 2 -- the header must exist and must actually contain the declarations
# it is supposed to. Step 3 would catch a header that is missing outright,
# but NOT one that is present and wrong in a way C forgives -- a `()`
# parameter list, or a plausible-but-wrong integer width. Those are checked
# textually here, before anything is compiled, so the failure names the
# missing declaration instead of surfacing as a link error.
# ---------------------------------------------------------------------------
[[ -f "$HDR" ]] || fail "dcc exited 0 but --emit-header did not produce $HDR"
[[ -s "$HDR" ]] || fail "--emit-header produced $HDR but it is empty"

require_header_line() {
  # $1 = exact expected line (fixed string, leading/trailing space ignored
  # by the -x-less grep -F), $2 = what its absence means.
  if ! grep -qF -- "$1" "$HDR"; then
    echo "----- generated header follows -----" >&2
    cat "$HDR" >&2
    echo "------------------------------------" >&2
    fail "generated header $HDR is missing $2 (expected to find the line '$1'; header dumped above)"
  fi
}

# (a) The u64 baseline: a uint64_t return with uint64_t parameters.
require_header_line 'uint64_t ffiAddU64(uint64_t a0, uint64_t a1);' \
  "the uint64_t-returning prototype for ffiAddU64"

# (b) The narrower widths. Three separate checks, because a generator that
# hardcoded 64-bit would still satisfy (a) alone.
require_header_line 'uint32_t ffiAddU32(uint32_t a0, uint32_t a1);' \
  "the uint32_t-returning prototype for ffiAddU32 (IntWidth.w32 -> uint32_t)"
require_header_line 'uint16_t ffiMaskU16(uint16_t a0, uint16_t a1);' \
  "the uint16_t-returning prototype for ffiMaskU16 (IntWidth.w16 -> uint16_t)"
require_header_line 'uint8_t ffiShiftU8(uint8_t a0, uint8_t a1);' \
  "the uint8_t-returning prototype for ffiShiftU8 (IntWidth.w8 -> uint8_t)"
# (b2) Mixed widths in one signature: each parameter mapped independently.
require_header_line 'uint32_t ffiWidenU8ToU32(uint8_t a0, uint32_t a1);' \
  "the mixed-width prototype for ffiWidenU8ToU32 (uint8_t param, uint32_t param and return)"

# (c) The by-value struct. The typedef itself, both of its fields in order,
# and a function actually returning it -- a header with the typedef but a
# uint64_t-returning ffiCheckPositive would compile and be silently wrong.
require_header_line 'typedef struct {' \
  "the struct typedef opening for the by-value Result type (ADR-0014)"
require_header_line '  uint64_t tag;' \
  "the Result struct's 'tag' field"
require_header_line '  uint64_t payload;' \
  "the Result struct's 'payload' field"
require_header_line '} DCDART_PACKED Result;' \
  "the Result struct typedef name/packing"
require_header_line 'Result ffiCheckPositive(uint64_t a0);' \
  "the by-value struct-returning prototype for ffiCheckPositive"
require_header_line 'Result ffiDoubleChecked(uint64_t a0);' \
  "the by-value struct-returning prototype for ffiDoubleChecked (.propagate() Ok path)"
require_header_line 'Result ffiAlwaysErr(uint64_t a0);' \
  "the by-value struct-returning prototype for ffiAlwaysErr (.propagate() Err path)"

# (d) The zero-argument form. This is the check that cannot be made from C:
# `uint64_t ffiConstant();` compiles, links, and accepts ffiConstant(1,2,3)
# without a diagnostic, because a pre-C23 empty list means "unspecified
# arguments", not "no arguments".
require_header_line 'uint64_t ffiConstant(void);' \
  "the zero-argument prototype for ffiConstant in its (void) form"
require_header_line 'uint8_t ffiConstantU8(void);' \
  "the zero-argument prototype for ffiConstantU8 in its (void) form"

# (d2) ...and no declaration anywhere in the header may use the empty `()`
# form. Stated as a negative too, so a future emitter change that adds a new
# zero-arg function the (d) list does not name still gets caught.
if grep -nE '^[A-Za-z_][A-Za-z0-9_ \*]*\(\) *;' "$HDR"; then
  fail "generated header $HDR declares a function with an empty '()' parameter list (lines above); in C that means 'unspecified arguments' and defeats the point of a generated header -- it must be '(void)'"
fi

# (e) main.c must not hand-write any declaration of its own. Without this
# the whole target silently degrades into a duplicate of m2-bitwise.
if grep -nE '^[[:space:]]*extern[[:space:]]' "$EXAMPLE_DIR/main.c"; then
  fail "$EXAMPLE_DIR/main.c declares an 'extern' prototype of its own (lines above) -- this target only proves anything if every declaration comes from the GENERATED header"
fi
if ! grep -qF '#include "ffi.h"' "$EXAMPLE_DIR/main.c"; then
  fail "$EXAMPLE_DIR/main.c does not '#include \"ffi.h\"' -- it must consume the generated header"
fi
if [[ -e "$EXAMPLE_DIR/ffi.h" ]]; then
  fail "a checked-in $EXAMPLE_DIR/ffi.h exists; it would shadow the generated header on the include path and could mask an emitter regression -- delete it, the harness generates the header per run"
fi

# ---------------------------------------------------------------------------
# Step 3 -- compile main.c against the GENERATED header and link it with the
# object. -I "$WORKDIR" is the only include path that can supply ffi.h, so if
# the emitter ever stopped writing a compilable header this step fails
# rather than silently falling back to something checked in.
#
# Plain hosted clang: no -ffreestanding, no -nostdlib. -Werror so a widened/
# narrowed prototype that merely warns (incompatible pointer or integer
# conversion) is a failure, not a note nobody reads.
# ---------------------------------------------------------------------------
if ! command -v clang >/dev/null 2>&1; then
  fail "clang not found on PATH, see docs/known-gaps.md GAP-0001"
fi

BUILD_LOG="$WORKDIR/build.log"
clang -std=c11 -Wall -Wextra -Werror \
  -I "$WORKDIR" \
  -o "$BIN" "$EXAMPLE_DIR/main.c" "$OBJ" \
  >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
if [[ $BUILD_STATUS -ne 0 ]]; then
  cat "$BUILD_LOG" >&2
  fail "hosted clang compile+link of main.c (against generated ffi.h) + ffi.o exited $BUILD_STATUS (log above)"
fi
[[ -f "$BIN" ]] || fail "clang reported success but $BIN was not produced"

# ---------------------------------------------------------------------------
# Step 4 -- run it, assert exit code 0. main.c returns a distinct code per
# check:
#   1-3   u64 add wrong (3 = the >32-bit case, i.e. a truncating prototype)
#   4-5   u64 mixed * ~/ % wrong
#   6-7   u32 wrong (7 = upper half of the return register not clean)
#   8-9   u16 wrong
#   10-12 u8 wrong
#   13    mixed-width parameter list wrong
#   14-16 by-value Result struct wrong (16 = full 64-bit payload)
#   17-19 by-value Result through .propagate() wrong (18/19 = Err path)
#   20-21 zero-argument function wrong
# ---------------------------------------------------------------------------
"$BIN"
ACTUAL=$?
if [[ $ACTUAL -ne 0 ]]; then
  fail "ffi_test exited $ACTUAL -- see core/examples/ffi-header/main.c for what that code means"
fi

# ---------------------------------------------------------------------------
# Step 5 -- PASS.
# ---------------------------------------------------------------------------
# Stated in the output, not buried in a comment: this target does NOT cover
# narrow-width values that ORIGINATE inside DCDart. The backend keeps u8/u16
# in 32-bit registers and neither masks an overflowing result nor
# zero-extends a materialized literal (`u8(200)` -> `mov w0, #-0x38`), so a
# C caller using the correctly-generated uint8_t prototype would read
# 0xFFFFFFC8. That is a backend defect, not a header one, and it is out of
# this target's scope to assert around -- said out loud so nobody reads this
# PASS as covering it.
echo "FFI-HEADER: note -- u8/u16 values originating inside DCDart (literals >= 0x80, overflowing shifts) are returned un-narrowed by the backend; this target's narrow-width checks stay inside the range where the object file matches its own generated prototype. Backend defect, reported separately."
echo "FFI-HEADER: PASS -- dcc --emit-header wrote a header from DC-IR -> uint64_t/uint32_t/uint16_t/uint8_t prototypes, mixed-width params, by-value Result struct typedef (tag/payload) and three Result-returning prototypes, zero-arg functions in (void) form and no '()' form anywhere -> main.c compiled against the generated header with zero hand-written externs (-Werror) -> linked with hosted clang -> real execution, all 21 value checks correct"
exit 0
