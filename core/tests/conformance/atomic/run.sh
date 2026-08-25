#!/usr/bin/env bash
# core/tests/conformance/atomic/run.sh
#
# Conformance target for ATOMIC READ-MODIFY-WRITE (ADR-0055, GAP-0039).
#
# WHY THIS HARNESS IS SHAPED THE WAY IT IS
#
# The property under test is ATOMICITY, and atomicity is invisible to every
# technique the other harnesses in this repo use. A single-threaded run cannot
# tell `lock xaddq` from `movq; incq; movq` — both return the same values, in
# the same order, every time. That is not a limitation of this harness; it is
# the entire content of GAP-0039: the wrong code works on one core and keeps
# working until the second one arrives.
#
# So value-checking is the WEAKEST step here, not the strongest, and it is
# labelled as such. The two steps that actually discriminate are:
#
#   Step 2  NO `__atomic_*` UNDEFINED SYMBOL. LLVM emits a libatomic call for
#           any atomic it cannot lower inline. In a @bare object that is a
#           runtime dependency and a CLAUDE.md rule 1 violation — a green
#           suite with that symbol present is a FAILED change. Checked by
#           name, not just via the allowlist, so the diagnostic says what
#           went wrong.
#
#   Step 3  THE PAIRED DISASSEMBLY. `examples/m2-atomic/atomic.dart` contains
#           `plainBumpTicks` and `atomicBumpTicks` — the same read-modify-write
#           on the same @bss word, one non-atomic and one atomic. The harness
#           requires a `lock` prefix in the atomic one AND THE ABSENCE OF ONE
#           in the plain one. The absence half is what makes the test mean
#           anything: without it, a `lock`-everything backend would pass, and
#           so would a grep against a file that happened to contain the word.
#
# Usage:
#   bash core/tests/conformance/atomic/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-atomic"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "ATOMIC: FAIL — $1" >&2; exit 1; }
setup_error() { echo "ATOMIC: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/atomic.dart" ]] || setup_error "missing $EXAMPLE_DIR/atomic.dart"
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

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-atomic.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    atomic.dart -o "$WORKDIR/atomic.o" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed"; }

VERIFY_OUT="$(cd "$CORE_DIR" && DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$WORKDIR/atomic.o" 2>&1)"
echo "$VERIFY_OUT"
grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT" \
  || fail "atomics introduced an undefined symbol — see the report above"

# ---------------------------------------------------------------------------
# Step 2 — NO LIBATOMIC. Checked by name and separately from step 1, so the
# diagnostic identifies the specific failure rather than "some symbol leaked".
#
# This is the step the coordinating instruction for this unit called out
# explicitly: an atomic must lower to an INSTRUCTION, not to a runtime helper
# call. `__atomic_fetch_add_8` and friends live in libatomic, and their
# presence would mean every @bare object using an atomic needs a library
# linked into kernel space.
# ---------------------------------------------------------------------------
UNDEF="$(llvm-nm -u --format=posix "$WORKDIR/atomic.o" 2>/dev/null | awk '{print $1}' | sed 's/^_//')"
if grep -qE '^__atomic_|^__sync_|^libat_' <<<"$UNDEF"; then
  echo "$UNDEF" >&2
  fail "an atomic lowered to a LIBCALL, not an instruction. That is a runtime dependency in a @bare object (CLAUDE.md rule 1) — do NOT fix this by adding the symbol to the allowlist."
fi
echo "ATOMIC: step 2 ok — no __atomic_*/__sync_* libcall; every atomic lowered to an instruction"

# ---------------------------------------------------------------------------
# Step 3 — THE DISCRIMINATOR. Per-function disassembly, atomic vs. plain.
#
# Splits the disassembly by function symbol so a `lock` found anywhere in the
# object cannot satisfy an assertion about one particular function.
# ---------------------------------------------------------------------------
DISASM_FILE="$WORKDIR/atomic.dis"
"$OBJDUMP" -d "$WORKDIR/atomic.o" >"$DISASM_FILE" 2>/dev/null

# Vacuous-pass guard: every count below would read zero on empty input.
[[ "$(grep -cE '^[[:space:]]+[0-9a-f]+:' "$DISASM_FILE")" -ge 1 ]] \
  || fail "$OBJDUMP produced no instructions; every assertion below would pass or fail vacuously"

# Prints the disassembly of one function only (from its `<name>:` header to
# the following blank line).
body_of() {
  awk -v fn="<$1>:" '
    index($0, fn) { inside = 1; next }
    inside && /^[[:space:]]*$/ { inside = 0 }
    inside { print }
  ' "$DISASM_FILE"
}

assert_has_lock() {
  local fn="$1" why="$2" body
  body="$(body_of "$fn")"
  [[ -n "$body" ]] || fail "no disassembly found for $fn — the symbol is missing from the object"
  if ! grep -qE '(^|[[:space:]])lock([[:space:]]|$)|lock[[:space:]]+(xadd|cmpxchg|add|or|and|xor|sub)' <<<"$body"; then
    echo "$body" >&2
    fail "$fn has NO \`lock\` prefix. $why"
  fi
}

assert_no_lock() {
  local fn="$1" why="$2" body
  body="$(body_of "$fn")"
  [[ -n "$body" ]] || fail "no disassembly found for $fn — the symbol is missing from the object"
  if grep -qE '(^|[[:space:]])lock([[:space:]]|$)' <<<"$body"; then
    echo "$body" >&2
    fail "$fn HAS a \`lock\` prefix. $why"
  fi
}

# The negative control comes FIRST. If this assertion ever fails, every
# positive assertion below it is meaningless, and the harness should say so
# before reporting a pass on any of them.
assert_no_lock plainBumpTicks \
  "This is the NEGATIVE CONTROL: an ordinary \`p.value = p.value + 1\`, which must stay a plain load/add/store. If it is locked, then this harness cannot distinguish atomic from non-atomic codegen and NONE of the assertions below prove anything."

assert_has_lock atomicBumpTicks \
  "Atomic.fetchAdd must lower to \`lock xadd\`. Unlocked, it is the exact lost-update GAP-0039 describes, and it will pass every value check in main.c."
assert_has_lock atomicFetchAddTicks "Atomic.fetchAdd must be a locked RMW."
assert_has_lock atomicFetchSubTicks "Atomic.fetchSub must be a locked RMW."
assert_has_lock atomicSetBit \
  "Atomic.fetchOr must be a locked RMW (x86 lowers a fetch-or whose result is used to a \`lock cmpxchg\` retry loop; either form is fine, an unlocked one is not)."
assert_has_lock atomicClearBit "Atomic.fetchAnd must be a locked RMW."
assert_has_lock atomicFlipBit "Atomic.fetchXor must be a locked RMW."
assert_has_lock atomicBump32 \
  "The u32 width must be locked too. This is the width-coverage case: a backend that hardcoded i64 would fail here and nowhere else."

# `xchg` with a memory operand is ALWAYS locked on x86 — the processor asserts
# the bus lock implicitly and the `lock` prefix is not encoded. So these two
# are asserted by mnemonic rather than by prefix, and a `lock`-based check
# would wrongly fail them.
for fn in tryAcquireLock releaseLock atomicStoreTicks; do
  BODY="$(body_of "$fn")"
  [[ -n "$BODY" ]] || fail "no disassembly found for $fn"
  grep -qE 'xchg[bwlq]?[[:space:]]' <<<"$BODY" \
    || { echo "$BODY" >&2; fail "$fn must lower to \`xchg\` (implicitly locked on x86). Atomic.exchange and a sequentially consistent Atomic.store are both an exchange; a plain \`mov\` here would be neither atomic nor a barrier."; }
done

# A seq_cst atomic LOAD on x86-64 is a plain `mov` — TSO already guarantees it
# — so there is nothing to assert about its prefix. Asserted instead: it is
# still THERE. An atomic load may not be elided or folded away.
LOAD_BODY="$(body_of atomicLoadTicks)"
grep -qE 'mov[bwlq][[:space:]]' <<<"$LOAD_BODY" \
  || { echo "$LOAD_BODY" >&2; fail "atomicLoadTicks emitted no load at all — an atomic load may not be elided"; }

echo "ATOMIC: step 3 ok — locked RMWs on every fetch-op at both widths, xchg for exchange/store, and the non-atomic control is provably unlocked"

# ---------------------------------------------------------------------------
# Step 4 — ATOMICITY MUST SURVIVE OPTIMIZATION.
#
# Same reasoning as tests/conformance/volatile/ step 3: the thing under test is
# something the optimizer is otherwise free to rewrite. A `lock` prefix that
# only appears at -O0 is worthless, because ADR-0042 ships -O2.
# ---------------------------------------------------------------------------
PROBE="$CORE_DIR/dcc/bin/_atomic_probe.dart"
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
( cd "$CORE_DIR" && dart dcc/bin/_atomic_probe.dart \
    "$EXAMPLE_DIR/atomic.dart" bare-x86_64 "$WORKDIR/atomic.ll" ) \
  >"$WORKDIR/emit.log" 2>&1
EMIT_STATUS=$?
rm -f "$PROBE"
[[ $EMIT_STATUS -eq 0 ]] || { cat "$WORKDIR/emit.log" >&2; fail "could not emit IR for atomic.dart"; }
[[ -s "$WORKDIR/atomic.ll" ]] || fail "emitted IR is empty"

# The IR half, checked separately so a failure says WHICH half broke.
grep -q 'atomicrmw add ptr' "$WORKDIR/atomic.ll" || fail "emitted IR has no 'atomicrmw add' — Atomic.fetchAdd did not lower to an atomic RMW"
grep -q 'atomicrmw xchg ptr' "$WORKDIR/atomic.ll" || fail "emitted IR has no 'atomicrmw xchg' — Atomic.exchange did not lower to an atomic RMW"
grep -q 'load atomic' "$WORKDIR/atomic.ll" || fail "emitted IR has no 'load atomic' — Atomic.load lowered to an ordinary load"
grep -q 'store atomic' "$WORKDIR/atomic.ll" || fail "emitted IR has no 'store atomic' — Atomic.store lowered to an ordinary store"
grep -q 'seq_cst' "$WORKDIR/atomic.ll" || fail "emitted IR has no ordering — an atomic with no ordering is not an atomic"

for OPT in 0 1 2 3 s; do
  OBJ="$WORKDIR/atomic_O$OPT.o"
  clang --target=x86_64-unknown-none-elf -ffreestanding -mno-red-zone \
    "-O$OPT" -c "$WORKDIR/atomic.ll" -o "$OBJ" >"$WORKDIR/cc.log" 2>&1 \
    || { cat "$WORKDIR/cc.log" >&2; fail "clang -O$OPT could not compile the emitted IR"; }

  OPT_UNDEF="$(llvm-nm -u --format=posix "$OBJ" 2>/dev/null | awk '{print $1}' | sed 's/^_//')"
  if grep -qE '^__atomic_|^__sync_' <<<"$OPT_UNDEF"; then
    echo "$OPT_UNDEF" >&2
    fail "-O$OPT turned an atomic into a libcall"
  fi

  DIS="$("$OBJDUMP" -d "$OBJ" 2>/dev/null)"
  [[ "$(grep -cE '^[[:space:]]+[0-9a-f]+:' <<<"$DIS")" -ge 1 ]] \
    || fail "$OBJDUMP produced no instructions for -O$OPT; the count below would pass vacuously"
  LOCKS="$(grep -cE '(^|[[:space:]])lock([[:space:]]|$)' <<<"$DIS")"
  [[ "$LOCKS" -ge 6 ]] \
    || { echo "$DIS" >&2; fail "-O$OPT emitted only $LOCKS locked instruction(s); expected at least 6 (fetchAdd x3, fetchSub, fetchOr, fetchAnd, fetchXor, u32 fetchAdd). The optimizer weakened an atomic."; }
  echo "  -O$OPT: $LOCKS locked instruction(s), no libcall"
done
echo "ATOMIC: step 4 ok — atomicity survives -O0/-O1/-O2/-O3/-Os"

# ---------------------------------------------------------------------------
# Step 5 — BEHAVIOUR, and the weakest step in this file.
#
# It proves the atomics compute the right VALUES. It cannot prove atomicity;
# see this file's header.
#
# Linked through tests/conformance/_lib/hosted-link.sh (GAP-0005), which picks
# the `-nostdlib` + `_start` path on Linux/x86-64 and an ordinary libc link
# everywhere else. This harness never had the Linux-only gate — it was written
# against tests/conformance/bss/'s portable shape rather than an M2 harness's —
# so sourcing the helper adds the freestanding-link evidence on Linux rather
# than removing a gate here. Nothing in this file asserts on a signal number:
# `llvm.trap` is `ud2`/SIGILL on Linux x86-64 and `brk`/SIGTRAP on macOS
# arm64, and no atomic in ADR-0055 can trap in any case (an atomic RMW wraps —
# it cannot trap, because the overflow is only observable after the write has
# already committed).
# ---------------------------------------------------------------------------
source "$CORE_DIR/tests/conformance/_lib/hosted-link.sh"

# The header is needed on BOTH paths (main.c includes it), and `dc_link` does
# not emit one, so it is generated here. The object built alongside it is
# unused on the hosted path — dc_link rebuilds its own — which costs one
# compile and keeps the helper's contract untouched.
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host \
    atomic.dart -o "$WORKDIR/atomic_host.o" --emit-header "$WORKDIR/atomic.h" ) \
    >"$WORKDIR/hostbuild.log" 2>&1 \
  || { cat "$WORKDIR/hostbuild.log" >&2; fail "dcc build --target host failed"; }
[[ -f "$WORKDIR/atomic.h" ]] || fail "--emit-header produced no header"

dc_link "$WORKDIR/atomic_test" "$EXAMPLE_DIR/main.c" "$WORKDIR/atomic.o" \
  "$EXAMPLE_DIR/atomic.dart" -I"$WORKDIR"

OUT="$("$WORKDIR/atomic_test")"; STATUS=$?
echo "$OUT"
[[ $STATUS -eq 0 ]] || fail "atomic_test exited $STATUS ($DC_LINK_MODE link) — a value read back wrong"
grep -q "ATOMIC: all correct" <<<"$OUT" || fail "unexpected output: $OUT"
echo "ATOMIC: step 5 ok — behaviour verified via the $DC_LINK_MODE link path"

echo "ATOMIC: PASS — every atomic lowers to a locked instruction at every -O level, never a libcall, the non-atomic control stays unlocked, and every value round-trips"
exit 0
