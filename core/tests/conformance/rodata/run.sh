#!/usr/bin/env bash
# core/tests/conformance/rodata/run.sh
#
# Conformance target for static read-only data (ADR-0040).
#
# Two halves, and the second is the unusual one:
#
#   BEHAVIOUR -- build for the host, link against real libc, run, and check
#   every value. Standard.
#
#   LAYOUT -- disassemble the FREESTANDING object and assert the emitted
#   bytes directly. This exists because the consumer reads these tables
#   through a raw `Pointer<T>` at a hand-written stride. If a length word or
#   class pointer were ever emitted in front of element 0, every index would
#   silently shift and return plausible garbage rather than fail. The kernel
#   asked for these to be assertions rather than documentation, and it was
#   right to: `mb-info` already had to carry alignment guards because an
#   assumption of exactly this class went unstated once.
#
# Layout is checked on bare-x86_64 SPECIFICALLY, not on the host. Section
# placement is target-dependent and measurably so: the same pointer-bearing
# constant lands in `.rodata` on bare targets, `.data.rel.ro` on Linux (PIE
# by default), a `__TEXT,__const`/`__DATA,__const` split on macOS, and a
# single `.rdata` on Windows. Bare metal is what oscortex_core ships, so bare
# metal is what gets asserted.
#
# Usage:
#   bash core/tests/conformance/rodata/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-rodata"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "RODATA: FAIL — $1" >&2; exit 1; }
setup_error() { echo "RODATA: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/rodata.dart" ]] || setup_error "missing $EXAMPLE_DIR/rodata.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing $EXAMPLE_DIR/main.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"

if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi
command -v clang >/dev/null 2>&1 || fail "clang not found on PATH"

OBJDUMP=""
for c in llvm-objdump objdump; do
  if command -v "$c" >/dev/null 2>&1; then OBJDUMP="$c"; break; fi
done
[[ -n "$OBJDUMP" ]] || fail "neither llvm-objdump nor objdump found; the layout half of this harness reads real bytes and cannot run without one"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-rodata.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    rodata.dart -o "$WORKDIR/rodata.o" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed"; }

if command -v llvm-nm >/dev/null 2>&1; then
  VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$WORKDIR/rodata.o" 2>&1)"
  echo "$VERIFY_OUT"
  grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT" \
    || fail "static data introduced an undefined symbol — a DEFINED global must never do that"
else
  fail "llvm-nm not found on PATH (required by verify-freestanding.sh)"
fi

# ---------------------------------------------------------------------------
# Step 2 — LAYOUT. Assert emitted sizes: elements only, no header, at the
# width the DECLARED type asked for.
#
#   regionBase   4 x u64 = 32 bytes (0x20)
#   regionLength 4 x u64 = 32 bytes (0x20)
#   regionType   4 x u32 = 16 bytes (0x10)
#   flags        4 x u8  =  4 bytes (0x04)
#
# A length word or class pointer would make each of these larger. A wrong
# element width would make them a different multiple.
# ---------------------------------------------------------------------------
SYMS="$("$OBJDUMP" -t "$WORKDIR/rodata.o" 2>/dev/null)"

check_size() {
  local sym="$1" want_hex="$2" want_desc="$3"
  local line
  line="$(grep -E "[[:space:]]${sym}\$" <<<"$SYMS" | head -1)"
  [[ -n "$line" ]] || fail "symbol \"$sym\" not found in the emitted object at all"
  grep -qE "\.rodata" <<<"$line" \
    || fail "\"$sym\" is not in .rodata on the freestanding target: $line"
  # objdump prints the size as the field just before the symbol name.
  local size
  size="$(awk '{print $(NF-1)}' <<<"$line")"
  if [[ "$((16#$size))" -ne "$((16#$want_hex))" ]]; then
    fail "\"$sym\" is $((16#$size)) bytes, expected $((16#$want_hex)) ($want_desc). A header in front of element 0, or a wrong element width, would look exactly like this."
  fi
  echo "  layout ok: $sym = $((16#$want_hex)) bytes ($want_desc)"
}

check_size regionBase   0000000000000020 "4 x u64, elements only"
check_size regionLength 0000000000000020 "4 x u64, elements only"
check_size regionType   0000000000000010 "4 x u32, width from the declared type"
check_size flags        0000000000000004 "4 x u8, tightest stride"
check_size tableDirectory 0000000000000018 "3 x pointer, a relocation table"

# The directory must carry REAL relocations into .rodata -- three of them,
# one per referenced table. Without these the words would be zeroes and every
# dereference through the directory would fault or read garbage.
RELOC_COUNT="$("$OBJDUMP" -r "$WORKDIR/rodata.o" 2>/dev/null | awk '/RELOCATION RECORDS FOR \[.rodata\]/{f=1;next} /^RELOCATION RECORDS/{f=0} f && /R_X86_64_64|ARM64_RELOC/{n++} END{print n+0}')"
[[ "$RELOC_COUNT" -ge 3 ]] \
  || fail "expected at least 3 relocations inside .rodata for tableDirectory, found $RELOC_COUNT — a table of Ref() must produce real linker relocations, not zero words"
echo "  layout ok: $RELOC_COUNT internal relocations emitted into .rodata"

# The two u64 tables must be at DIFFERENT offsets. Identical-looking data
# must not be merged: `regionBase` and `regionLength` share their first
# element, and a merged pair would break type identity for descriptors later.
BASE_OFF="$(grep -E "[[:space:]]regionBase\$" <<<"$SYMS" | awk '{print $1}')"
LEN_OFF="$(grep -E "[[:space:]]regionLength\$" <<<"$SYMS" | awk '{print $1}')"
[[ "$BASE_OFF" != "$LEN_OFF" ]] \
  || fail "regionBase and regionLength were emitted at the SAME offset — distinct declarations must have distinct addresses"
echo "  layout ok: distinct tables at distinct offsets ($BASE_OFF vs $LEN_OFF)"

# And nothing may be unnamed_addr / mergeable: a mergeable section would let
# the linker collapse byte-identical globals to one address.
if grep -qE "\.rodata\.cst|\.rodata\.str" <<<"$("$OBJDUMP" -h "$WORKDIR/rodata.o" 2>/dev/null)"; then
  fail "a mergeable .rodata.cst*/.rodata.str* section was emitted; globals must not be unnamed_addr (the linker may merge byte-identical ones, destroying identity)"
fi
echo "  layout ok: no mergeable sections — identical globals cannot be collapsed"

# ---------------------------------------------------------------------------
# Step 3 — BEHAVIOUR. Build for the host, link ordinarily, run.
#
# No Linux/x86-64 gate: this links against real libc like
# examples/demo-collatz does, so it runs natively on macOS, Linux and Windows.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host \
    rodata.dart -o "$WORKDIR/rodata_host.o" --emit-header "$WORKDIR/rodata.h" ) \
    >"$WORKDIR/hostbuild.log" 2>&1 \
  || { cat "$WORKDIR/hostbuild.log" >&2; fail "dcc build --target host failed"; }

[[ -f "$WORKDIR/rodata.h" ]] || fail "--emit-header produced no header"

clang -I"$WORKDIR" -o "$WORKDIR/rodata_test" "$EXAMPLE_DIR/main.c" \
  "$WORKDIR/rodata_host.o" >"$WORKDIR/link.log" 2>&1 \
  || { cat "$WORKDIR/link.log" >&2; fail "hosted link failed"; }

OUT="$("$WORKDIR/rodata_test")"; STATUS=$?
echo "$OUT"
[[ $STATUS -eq 0 ]] || fail "rodata_test exited $STATUS — a value read back wrong"
grep -q "RODATA: all correct" <<<"$OUT" || fail "unexpected output: $OUT"

echo "RODATA: PASS — @rodata emits elements-only tables at the declared width, freestanding-clean, distinct declarations at distinct addresses, read correctly through a raw Pointer<T> at runtime"
exit 0
