#!/usr/bin/env bash
# core/tests/conformance/fence/run.sh
#
# Conformance target for MEMORY BARRIERS (ADR-0056, GAP-0033).
#
# WHAT THIS CAN AND CANNOT ASSERT, stated first because the honest limit is
# unusual and reading a green result as more than it is would be worse than
# having no test.
#
# On x86-64, TSO already provides acquire and release ordering in hardware, so
# `fence acquire`, `fence release` and `fence acq_rel` correctly emit NO
# MACHINE INSTRUCTION. They are not decorative — they constrain the COMPILER,
# which is free to reorder the surrounding accesses without them — but the
# constraint is invisible in a disassembly. So:
#
#   * the DISCRIMINATOR for those three is the emitted LLVM IR (step 2), the
#     same resolution ADR-0041/GAP-0036 reached for `volatile`, and for the
#     same reason;
#   * `Ordering.seqCst` is the only one that reaches the machine, as `mfence`,
#     and it is the only one asserted in the disassembly (step 3);
#   * step 3 ALSO asserts the four cheap orderings emit NO `mfence`. That is
#     the assertion with teeth: an implementation that mapped every ordering
#     to seq_cst would satisfy every other check in this file while making
#     each barrier in the kernel cost an `mfence` it does not need.
#
# What NO test here can currently show is a differential — "without the fence
# the compiler reorders these two accesses, with it it does not". Every
# access in the example goes through `Pointer<T>.value`, which ADR-0041 makes
# VOLATILE, and volatile accesses already may not be reordered relative to one
# another. So on today's language the fences in `examples/m2-fence/fence.dart`
# are redundant with a guarantee `Pointer<T>` is handing out for free. That
# stops being true the moment GAP-0034's device-memory/ordinary-memory split
# lands and ordinary pointer access becomes non-volatile. Recorded as
# GAP-0043 rather than left for someone to discover.
#
# Usage:
#   bash core/tests/conformance/fence/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-fence"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "FENCE: FAIL — $1" >&2; exit 1; }
setup_error() { echo "FENCE: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/fence.dart" ]] || setup_error "missing $EXAMPLE_DIR/fence.dart"
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
command -v llvm-nm >/dev/null 2>&1 || fail "llvm-nm not found on PATH (required by verify-freestanding.sh)"

OBJDUMP=""
for c in llvm-objdump objdump; do
  if command -v "$c" >/dev/null 2>&1; then OBJDUMP="$c"; break; fi
done
[[ -n "$OBJDUMP" ]] || fail "neither llvm-objdump nor objdump found; step 3 reads real instructions and cannot run without one"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-fence.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine.
#
# A fence has no runtime component by construction, so the interesting failure
# this catches is a backend that reached for a helper.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    fence.dart -o "$WORKDIR/fence.o" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed"; }

VERIFY_OUT="$(cd "$CORE_DIR" && DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$WORKDIR/fence.o" 2>&1)"
echo "$VERIFY_OUT"
grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT" \
  || fail "a barrier introduced an undefined symbol — see the report above"

# ---------------------------------------------------------------------------
# Step 2 — THE DISCRIMINATOR for acquire/release/acqRel/compilerOnly.
#
# The emitted IR must name each ordering exactly. Checked before the machine
# code so a failure says which half broke: a missing ordering here is a
# lowering regression, while a missing `mfence` below with the IR correct
# would be something far stranger.
# ---------------------------------------------------------------------------
PROBE="$CORE_DIR/dcc/bin/_fence_probe.dart"
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
( cd "$CORE_DIR" && dart dcc/bin/_fence_probe.dart \
    "$EXAMPLE_DIR/fence.dart" bare-x86_64 "$WORKDIR/fence.ll" ) \
  >"$WORKDIR/emit.log" 2>&1
EMIT_STATUS=$?
rm -f "$PROBE"
[[ $EMIT_STATUS -eq 0 ]] || { cat "$WORKDIR/emit.log" >&2; fail "could not emit IR for fence.dart"; }
[[ -s "$WORKDIR/fence.ll" ]] || fail "emitted IR is empty"

grep -qE '^[[:space:]]*fence acquire$' "$WORKDIR/fence.ll" \
  || fail "emitted IR has no 'fence acquire'. On x86-64 this ordering emits no instruction, so the IR is the ONLY place it can be observed — a lowering that dropped it would pass every other check in this file."
grep -qE '^[[:space:]]*fence release$' "$WORKDIR/fence.ll" \
  || fail "emitted IR has no 'fence release' — see the note on 'fence acquire' above"
grep -qE '^[[:space:]]*fence acq_rel$' "$WORKDIR/fence.ll" \
  || fail "emitted IR has no 'fence acq_rel' — Ordering.acqRel must map to LLVM's acq_rel, not to seq_cst"
grep -qE '^[[:space:]]*fence seq_cst$' "$WORKDIR/fence.ll" \
  || fail "emitted IR has no 'fence seq_cst'"
grep -q 'asm sideeffect "", "~{memory}"' "$WORKDIR/fence.ll" \
  || fail "emitted IR has no empty memory-clobbering asm — Ordering.compilerOnly must be a compiler barrier. LLVM has no 'fence' ordering that means this; 'fence monotonic' is not even legal IR."

# Each ordering must appear the right number of times. A lowering that
# collapsed all five onto one ordering would satisfy every grep above if the
# example happened to use each ordering somewhere; counting is what forbids it.
count_ir() { grep -cE "^[[:space:]]*fence $1\$" "$WORKDIR/fence.ll"; }
[[ "$(count_ir acquire)" -eq 1 ]] || fail "expected exactly 1 'fence acquire' in the IR, got $(count_ir acquire)"
[[ "$(count_ir release)" -eq 1 ]] || fail "expected exactly 1 'fence release' in the IR, got $(count_ir release)"
[[ "$(count_ir acq_rel)" -eq 1 ]] || fail "expected exactly 1 'fence acq_rel' in the IR, got $(count_ir acq_rel)"
[[ "$(count_ir seq_cst)" -eq 1 ]] || fail "expected exactly 1 'fence seq_cst' in the IR, got $(count_ir seq_cst)"
echo "FENCE: step 2 ok — all five orderings emitted distinctly in the IR, one each"

# ---------------------------------------------------------------------------
# Step 3 — THE COST MODEL. seqCst pays an `mfence`; nothing else does.
#
# This is the assertion with teeth. Mapping every ordering to seq_cst is the
# easy, safe-looking mistake, and it would make every barrier in a kernel cost
# a serializing instruction it does not need. Asserted per function, so an
# `mfence` anywhere in the object cannot satisfy a claim about one function.
# ---------------------------------------------------------------------------
DISASM_FILE="$WORKDIR/fence.dis"
"$OBJDUMP" -d "$WORKDIR/fence.o" >"$DISASM_FILE" 2>/dev/null
[[ "$(grep -cE '^[[:space:]]+[0-9a-f]+:' "$DISASM_FILE")" -ge 1 ]] \
  || fail "$OBJDUMP produced no instructions; every assertion below would pass or fail vacuously"

body_of() {
  awk -v fn="<$1>:" '
    index($0, fn) { inside = 1; next }
    inside && /^[[:space:]]*$/ { inside = 0 }
    inside { print }
  ' "$DISASM_FILE"
}

SEQ_BODY="$(body_of storeThenLoadOther)"
[[ -n "$SEQ_BODY" ]] || fail "no disassembly found for storeThenLoadOther"
grep -qE '(mfence|lock)' <<<"$SEQ_BODY" \
  || { echo "$SEQ_BODY" >&2; fail "Ordering.seqCst emitted NO barrier instruction. It is the only ordering that forbids StoreLoad reordering, which x86 TSO otherwise permits — without it, Dekker's algorithm and every seqlock reader are broken."; }

for fn in publish consume handoff compilerBarrierOnly; do
  BODY="$(body_of "$fn")"
  [[ -n "$BODY" ]] || fail "no disassembly found for $fn"
  if grep -qE '(mfence|lock)' <<<"$BODY"; then
    echo "$BODY" >&2
    fail "$fn emitted a serializing instruction. acquire/release/acqRel/compilerOnly are all FREE on x86-64 (TSO provides them in hardware; the fence constrains only the compiler). An mfence here means the ordering was widened to seq_cst somewhere, which is correct but costs a serializing instruction on every barrier in the kernel."
  fi
done
echo "FENCE: step 3 ok — seqCst pays an mfence; acquire/release/acqRel/compilerOnly are free, as x86 TSO allows"

# ---------------------------------------------------------------------------
# Step 4 — THE BARRIER MUST SURVIVE OPTIMIZATION. Same reasoning as
# tests/conformance/volatile/ step 3: ADR-0042 ships -O2, and a fence that
# only exists at -O0 is not a fence.
# ---------------------------------------------------------------------------
for OPT in 0 1 2 3 s; do
  OBJ="$WORKDIR/fence_O$OPT.o"
  clang --target=x86_64-unknown-none-elf -ffreestanding -mno-red-zone \
    "-O$OPT" -c "$WORKDIR/fence.ll" -o "$OBJ" >"$WORKDIR/cc.log" 2>&1 \
    || { cat "$WORKDIR/cc.log" >&2; fail "clang -O$OPT could not compile the emitted IR"; }
  DIS="$("$OBJDUMP" -d "$OBJ" 2>/dev/null)"
  [[ "$(grep -cE '^[[:space:]]+[0-9a-f]+:' <<<"$DIS")" -ge 1 ]] \
    || fail "$OBJDUMP produced no instructions for -O$OPT; the count below would pass vacuously"
  FENCES="$(grep -cE 'mfence' <<<"$DIS")"
  [[ "$FENCES" -ge 1 ]] \
    || { echo "$DIS" >&2; fail "-O$OPT emitted no mfence at all — the seq_cst barrier was optimized away"; }
  echo "  -O$OPT: $FENCES mfence(s) — the seq_cst barrier survived"
done
echo "FENCE: step 4 ok — barriers survive -O0/-O1/-O2/-O3/-Os"

# ---------------------------------------------------------------------------
# Step 5 — BEHAVIOUR. Weakest step, as in tests/conformance/atomic/: it proves
# a fence does not BREAK the accesses around it. A single thread observes its
# own accesses in program order regardless, so it cannot show ordering.
#
# Linked through tests/conformance/_lib/hosted-link.sh (GAP-0005): `-nostdlib`
# + `_start` on Linux/x86-64, ordinary libc link everywhere else. No signal
# number is asserted anywhere in this file, and no fence can trap.
# ---------------------------------------------------------------------------
source "$CORE_DIR/tests/conformance/_lib/hosted-link.sh"

# Needed on both link paths, and `dc_link` does not emit a header.
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host \
    fence.dart -o "$WORKDIR/fence_host.o" --emit-header "$WORKDIR/fence.h" ) \
    >"$WORKDIR/hostbuild.log" 2>&1 \
  || { cat "$WORKDIR/hostbuild.log" >&2; fail "dcc build --target host failed"; }
[[ -f "$WORKDIR/fence.h" ]] || fail "--emit-header produced no header"

dc_link "$WORKDIR/fence_test" "$EXAMPLE_DIR/main.c" "$WORKDIR/fence.o" \
  "$EXAMPLE_DIR/fence.dart" -I"$WORKDIR"

OUT="$("$WORKDIR/fence_test")"; STATUS=$?
echo "$OUT"
[[ $STATUS -eq 0 ]] || fail "fence_test exited $STATUS ($DC_LINK_MODE link) — a value read back wrong"
grep -q "FENCE: all correct" <<<"$OUT" || fail "unexpected output: $OUT"
echo "FENCE: step 5 ok — behaviour verified via the $DC_LINK_MODE link path"

echo "FENCE: PASS — five distinct orderings in the IR, seqCst pays an mfence and the other four are free, all survive -O0..-Os, and every access round-trips"
exit 0
