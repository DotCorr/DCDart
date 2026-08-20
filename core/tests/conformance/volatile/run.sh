#!/usr/bin/env bash
# core/tests/conformance/volatile/run.sh
#
# Asserts that an MMIO access SURVIVES OPTIMIZATION (ADR-0041).
#
# WHY THIS EXISTS, AND WHY IT LOOKS NOTHING LIKE THE OTHER HARNESSES
#
# `tests/conformance/m1-pointer/` already covers M1's exit criterion: write a
# memory-mapped register through `Pointer<u32>`, read it back, check the
# value. It passed, and it kept passing at `-O2` while the compiler emitted
# this:
#
#     -O0                              -O2
#       movl %esi, (%rdi)   store        movl %esi, %eax   <- returns what it wrote
#       movl (%rdi), %eax   load         movl %esi, (%rdi)
#       retq                             retq              <- THE LOAD IS GONE
#
# The returned value stays correct, so a value-checking harness cannot see it.
# For a real hardware register the read-back IS the operation — status bits
# change, write-only bits read differently, devices acknowledge on read.
#
# That is known-gaps GAP-0027 in its sharpest form: every harness in this repo
# checks what a program COMPUTED, and nothing checks that the hardware was
# TOUCHED. This harness checks the access itself, by counting instructions in
# the emitted object at several optimization levels.
#
# It is not a full answer to GAP-0027 — that needs `dc-test --qemu` with a
# device trace, so a missing access fails against real emulated hardware
# rather than against a disassembly. This is the part that can be done today
# with no new infrastructure, and it pins the specific regression that was
# live in this tree.
#
# Usage:
#   bash core/tests/conformance/volatile/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m1-pointer"

fail() { echo "VOLATILE: FAIL — $1" >&2; exit 1; }
setup_error() { echo "VOLATILE: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/mmio.dart" ]] || setup_error "missing $EXAMPLE_DIR/mmio.dart"
command -v clang >/dev/null 2>&1 || fail "clang not found on PATH"
command -v dart >/dev/null 2>&1 || fail "dart not found on PATH"

OBJDUMP=""
for c in llvm-objdump objdump; do
  if command -v "$c" >/dev/null 2>&1; then OBJDUMP="$c"; break; fi
done
[[ -n "$OBJDUMP" ]] || fail "neither llvm-objdump nor objdump found; this harness reads instructions and cannot run without one"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-volatile.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — emit the IR through the same backend entry point `dcc` uses.
#
# `dcc` writes its .ll to a temp dir and deletes it, and this harness needs
# to compile the SAME IR at several -O levels rather than build several times.
# The probe is written into dcc/bin so it can resolve `package:` imports, and
# removed immediately.
# ---------------------------------------------------------------------------
PROBE="$CORE_DIR/dcc/bin/_volatile_probe.dart"
cat > "$PROBE" <<'DART'
import 'dart:io';
import 'package:backend/llvm_emit.dart';
import 'package:backend/targets.dart';
import 'package:dcc_lower/lower.dart';

Future<void> main(List<String> args) async {
  final module = await lowerToDCModule(
    args[0],
    preludeUri: Platform.script.resolve('../../runtime/dc-core-bare/prelude.dart'),
  );
  final target = DCTarget.parse(args[1], hostOsName: 'linux', hostArchName: 'x64');
  File(args[2]).writeAsStringSync(
    emitModule(module, targetTriple: target.triple, noRedZone: target.forbidsRedZone),
  );
}
DART
( cd "$CORE_DIR" && dart dcc/bin/_volatile_probe.dart \
    "$EXAMPLE_DIR/mmio.dart" bare-x86_64 "$WORKDIR/mmio.ll" ) \
  >"$WORKDIR/emit.log" 2>&1
EMIT_STATUS=$?
rm -f "$PROBE"
[[ $EMIT_STATUS -eq 0 ]] || { cat "$WORKDIR/emit.log" >&2; fail "could not emit IR for mmio.dart"; }
[[ -s "$WORKDIR/mmio.ll" ]] || fail "emitted IR is empty"

# ---------------------------------------------------------------------------
# Step 2 — the IR itself must say `volatile`. Checked separately from the
# machine code so a failure says WHICH half broke: a missing keyword here is
# a lowering regression, while a missing instruction below with the keyword
# present would be something far stranger.
# ---------------------------------------------------------------------------
grep -q 'load volatile' "$WORKDIR/mmio.ll" \
  || fail "emitted IR has no 'load volatile' — Pointer<T>.value reads must be volatile (ADR-0041). Got: $(grep -E 'load|store' "$WORKDIR/mmio.ll" | tr '\n' ' ')"
grep -q 'store volatile' "$WORKDIR/mmio.ll" \
  || fail "emitted IR has no 'store volatile' — Pointer<T>.value writes must be volatile (ADR-0041)"
echo "VOLATILE: step 2 ok — emitted IR marks the MMIO load and store volatile"

# ---------------------------------------------------------------------------
# Step 3 — THE REGRESSION. The access must survive every optimization level.
#
# Counts real memory operations against %rdi (the pointer argument). At -O2
# without volatile the load disappears and the count drops from 2 to 1, while
# m1-pointer's value check keeps passing.
# ---------------------------------------------------------------------------
for OPT in 0 1 2 3 s; do
  OBJ="$WORKDIR/mmio_O$OPT.o"
  clang --target=x86_64-unknown-none-elf -ffreestanding -mno-red-zone \
    "-O$OPT" -c "$WORKDIR/mmio.ll" -o "$OBJ" >"$WORKDIR/cc.log" 2>&1 \
    || { cat "$WORKDIR/cc.log" >&2; fail "clang -O$OPT could not compile the emitted IR"; }

  DISASM="$("$OBJDUMP" -d "$OBJ" 2>/dev/null)"
  # Vacuous-pass guard: every count below would read zero on empty input.
  [[ "$(grep -cE '^[[:space:]]+[0-9a-f]+:' <<<"$DISASM")" -ge 1 ]] \
    || fail "$OBJDUMP produced no instructions for -O$OPT; the counts below would all read zero and pass vacuously"

  STORES="$(grep -cE 'mov[lbwq][[:space:]]+%e?[a-z0-9]+, \(%rdi\)' <<<"$DISASM")"
  LOADS="$(grep -cE 'mov[lbwq][[:space:]]+\(%rdi\), %e?[a-z0-9]+' <<<"$DISASM")"

  if [[ "$STORES" -lt 1 ]]; then
    echo "$DISASM" >&2
    fail "-O$OPT emitted NO store through the MMIO pointer. The register write was optimized away."
  fi
  if [[ "$LOADS" -lt 1 ]]; then
    echo "$DISASM" >&2
    fail "-O$OPT emitted NO load through the MMIO pointer — the read-back was eliminated. This is the exact regression ADR-0041 fixes: the returned VALUE stays correct, so m1-pointer's own harness cannot see it, but the hardware is never read."
  fi
  echo "  -O$OPT: $STORES store(s), $LOADS load(s) through the MMIO pointer — access survived"
done

echo "VOLATILE: PASS — Pointer<T>.value emits volatile load/store, and the MMIO access survives -O0/-O1/-O2/-O3/-Os intact"
exit 0
