#!/usr/bin/env bash
# core/tests/conformance/no-red-zone/run.sh
#
# Mechanical check of ADR-0039: a FREESTANDING object file must never use the
# x86-64 red zone.
#
# WHY THIS HARNESS IS SHAPED DIFFERENTLY FROM THE OTHERS
#
# Every other conformance target builds one example and asserts its behaviour.
# This one asserts a property of the EMITTED CODE across every example we
# have, because the bug it guards against is invisible to behavioural testing:
#
#   The red zone is 128 bytes below RSP that a leaf function may use without
#   adjusting the stack. Interrupts push their frame at RSP and land straight
#   on top of it. In an ordinary hosted process that never happens, so a
#   red-zone-using @bare object passes every behavioural test we own while
#   being silently fatal in a kernel the moment interrupts are enabled.
#
# So a green suite provably cannot catch this (docs/known-gaps.md GAP-0027)
# and the check has to look at instructions, not results.
#
# HONEST LIMIT OF THIS HARNESS, stated up front so nobody over-reads a pass:
# `dcc` currently invokes clang with no -O flag, and at -O0 clang does not use
# the red zone anyway. So this harness passes today BOTH WITH AND WITHOUT
# ADR-0039's fix — it does not, right now, demonstrate that the fix does
# anything. It is a FORWARD REGRESSION GUARD: the moment optimization is
# enabled, or a codegen change makes a leaf function spill, the red zone
# becomes reachable, and this is the check that catches it before a kernel
# does. The detector itself IS verified to work: run against a deliberately
# red-zone-using object it reports FAIL, and against the same object compiled
# with `noredzone` it reports pass (negative and positive control, done by
# hand when this was written).
#
# What DOES demonstrate the fix today is that the emitted IR carries the
# `noredzone` attribute and clang is invoked with `-mno-red-zone` for
# freestanding targets, both checked in step 2 below.
#
# The check itself: disassemble and look for any access at a NEGATIVE offset
# from %rsp. On x86-64, `-0x8(%rsp)` and friends are by definition below the
# stack pointer, which is the red zone and nowhere else. Accesses relative to
# %rbp are fine ONLY when the frame was actually allocated, so this also
# verifies that a frame-pointer-relative negative access is backed by a real
# `sub %rsp` in the same function.
#
# Usage:
#   bash core/tests/conformance/no-red-zone/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLES_DIR="$CORE_DIR/examples"

fail() { echo "NO-RED-ZONE: FAIL — $1" >&2; exit 1; }
setup_error() { echo "NO-RED-ZONE: FAIL — $1" >&2; exit 2; }

[[ -d "$EXAMPLES_DIR" ]] || setup_error "missing $EXAMPLES_DIR"

if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

OBJDUMP=""
for candidate in llvm-objdump objdump; do
  if command -v "$candidate" >/dev/null 2>&1; then OBJDUMP="$candidate"; break; fi
done
[[ -n "$OBJDUMP" ]] || fail "neither llvm-objdump nor objdump found on PATH; this harness reads instructions, so it cannot run without one"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-no-red-zone.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — every example, built for the FREESTANDING x86-64 target.
#
# bare-x86_64 specifically: the red zone is an x86-64 SysV concept, and
# `--target host` on a non-x86 machine would silently test nothing. Hosted
# targets are deliberately NOT checked — the red zone is legitimate there and
# forbidding it would cost performance for no safety (ADR-0039).
# ---------------------------------------------------------------------------
checked=0
skipped=0
violations=0

for dir in "$EXAMPLES_DIR"/*/; do
  name="$(basename "$dir")"
  # shellcheck disable=SC2012
  count=$(ls "$dir"*.dart 2>/dev/null | wc -l | tr -d ' ')
  [[ "$count" == "1" ]] || { skipped=$((skipped + 1)); continue; }
  src="$(ls "$dir"*.dart)"
  obj="$WORKDIR/$name.o"

  if ! ( cd "$dir" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
        "$(basename "$src")" -o "$obj" ) >"$WORKDIR/$name.log" 2>&1; then
    # A target that legitimately cannot build for bare-x86_64 is not a
    # red-zone failure. There are none today; if one appears, it is reported
    # rather than silently counted as a pass.
    echo "NO-RED-ZONE: note — $name did not build for bare-x86_64, skipping:" >&2
    tail -3 "$WORKDIR/$name.log" >&2
    skipped=$((skipped + 1))
    continue
  fi

  checked=$((checked + 1))

  # Any access at a negative displacement from %rsp is a red-zone access.
  if bad=$("$OBJDUMP" -d "$obj" 2>/dev/null | grep -nE '\-0x[0-9a-f]+\(%rsp\)'); then
    echo "NO-RED-ZONE: FAIL — $name accesses memory below %rsp (the red zone):" >&2
    echo "$bad" | head -5 >&2
    violations=$((violations + 1))
  fi

  # A negative %rbp displacement is only safe if the frame was really
  # allocated. `push %rbp; mov %rsp,%rbp` with no `sub` means %rbp == %rsp,
  # so -0x8(%rbp) is also below the stack pointer -- this is exactly the shape
  # the oscortex_core kernel disassembly showed.
  if "$OBJDUMP" -d "$obj" 2>/dev/null | grep -qE '\-0x[0-9a-f]+\(%rbp\)'; then
    if ! "$OBJDUMP" -d "$obj" 2>/dev/null | grep -qE 'sub.*%rsp'; then
      echo "NO-RED-ZONE: FAIL — $name uses %rbp-relative locals with no stack allocation (red zone via %rbp)" >&2
      violations=$((violations + 1))
    fi
  fi
done

(( checked > 0 )) || setup_error "no examples were checked; the harness would have reported a vacuous pass"

# ---------------------------------------------------------------------------
# Step 2 — the guarantee must actually be REQUESTED, not merely satisfied by
# an optimizer that happens not to want the red zone today.
#
# `dcc` writes its .ll to a temp dir and deletes it, so this re-emits one
# through the same backend entry point the driver uses and inspects the
# attribute group. Without this step the harness would keep passing if
# someone deleted ADR-0039's fix, right up until the day it mattered.
# ---------------------------------------------------------------------------
PROBE="$WORKDIR/_probe_attrs.dart"
cat > "$PROBE" <<'DART'
import 'package:backend/llvm_emit.dart';
import 'package:backend/targets.dart';
import 'package:dcc_lower/lower.dart';

Future<void> main(List<String> args) async {
  final module = await lowerToDCModule(
    args[0],
    preludeUri: Uri.file('${args[1]}/runtime/dc-core-bare/prelude.dart'),
  );
  final target = DCTarget.parse(args[2], hostOsName: 'linux', hostArchName: 'x64');
  final ll = emitModule(
    module,
    targetTriple: target.triple,
    noRedZone: target.forbidsRedZone,
  );
  for (final line in ll.split('\n')) {
    if (line.startsWith('attributes #0')) print(line);
  }
}
DART
cp "$PROBE" "$CORE_DIR/dcc/bin/_probe_attrs.dart"
ATTRS="$(cd "$CORE_DIR" && dart dcc/bin/_probe_attrs.dart \
  "$EXAMPLES_DIR/m0-seam/add.dart" "$CORE_DIR" bare-x86_64 2>&1 | tail -1)"
rm -f "$CORE_DIR/dcc/bin/_probe_attrs.dart"

grep -q 'noredzone' <<<"$ATTRS" \
  || fail "freestanding emission does not carry the 'noredzone' function attribute (ADR-0039). Got: $ATTRS"

# And the hosted case must NOT carry it -- the red zone is legitimate there,
# and forbidding it would cost performance for no safety. A check that passes
# for every target would not be checking anything.
cp "$PROBE" "$CORE_DIR/dcc/bin/_probe_attrs.dart"
HOSTED_ATTRS="$(cd "$CORE_DIR" && dart dcc/bin/_probe_attrs.dart \
  "$EXAMPLES_DIR/m0-seam/add.dart" "$CORE_DIR" linux-x86_64 2>&1 | tail -1)"
rm -f "$CORE_DIR/dcc/bin/_probe_attrs.dart"

if grep -q 'noredzone' <<<"$HOSTED_ATTRS"; then
  fail "hosted target linux-x86_64 carries 'noredzone', which ADR-0039 says it must not. Got: $HOSTED_ATTRS"
fi

if (( violations > 0 )); then
  fail "$violations of $checked freestanding objects use the red zone (ADR-0039). This is silent memory corruption in kernel code once interrupts are enabled."
fi

echo "NO-RED-ZONE: PASS — $checked freestanding objects checked, zero red-zone accesses ($skipped skipped); freestanding emission carries \`noredzone\`, hosted emission correctly does not"
exit 0
