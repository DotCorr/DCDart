#!/usr/bin/env bash
# core/tests/conformance/str/run.sh
#
# Conformance target for string slices (ADR-0053).
#
# Two assertions carry this target:
#
#   utf8Len   "héllo" is 6 BYTES and 5 Dart UTF-16 code units. Spec §7 names
#             that the largest single source of semantic drift from upstream
#             Dart, so it is asserted rather than documented -- a `.length`
#             that returned 5 would be Dart-correct and DCDart-wrong.
#   sumBytes  walks a literal's bytes through `.address` and sums them, which
#             proves the pointer reaches real .rodata content rather than a
#             plausible number. A length check alone would pass on a slice
#             pointing anywhere at all.
#
# Usage:
#   bash core/tests/conformance/str/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-str"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWFOR="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "STR: FAIL — $1" >&2; exit 1; }
setup_error() { echo "STR: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/str.dart" ]] || setup_error "missing $EXAMPLE_DIR/str.dart"
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

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-str.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    str.dart -o "$WORKDIR/str.o" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed"; }

if command -v llvm-nm >/dev/null 2>&1; then
  VERIFY_OUT="$(DCDART_ALLOWFOR="$ALLOWFOR" bash "$VERIFY_SCRIPT" "$WORKDIR/str.o" 2>&1)"
  echo "$VERIFY_OUT"
  grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT" \
    || fail "static data introduced an undefined symbol — a DEFINED global must never do that"
else
  fail "llvm-nm not found on PATH (required by verify-freestanding.sh)"
fi

# ---------------------------------------------------------------------------
# Step 1b — LITERAL BYTES, read out of the object rather than inferred.
#
# Only "ABC" is asserted, and the reason is worth stating because it looks
# like an omission. `Str("hello").length` folds to the constant 5 at compile
# time, which leaves the pointer dead, and LLVM then drops the `internal`
# global entirely -- so "hello" is CORRECTLY absent from the object. A dead
# literal costing zero bytes is the behaviour we want in `@bare`. "ABC" is
# the literal `sumBytes` actually walks, so it is the one that must survive,
# and it is checked by reading .rodata rather than by trusting the sum.
# ---------------------------------------------------------------------------
if command -v llvm-objdump >/dev/null 2>&1; then
  RO="$(llvm-objdump -s -j .rodata "$WORKDIR/str.o" 2>/dev/null)"
  # VACUOUS-PASS GUARD: an objdump that cannot read the format prints nothing
  # under 2>/dev/null, and a grep for content would then simply not match.
  grep -qE '^ [0-9a-f]{4} ' <<<"$RO" \
    || fail "llvm-objdump printed no .rodata contents; the byte check below would be inconclusive rather than passing"
  grep -q "ABC" <<<"$RO" \
    || fail "the dereferenced literal's bytes are not in .rodata; got: $(tr -s ' ' <<<"$RO" | tail -3)"
  echo "  literal bytes ok: dereferenced literal materialized in .rodata"
fi

# ---------------------------------------------------------------------------
# Step 1c — INTERNING, asserted on the emitted IR rather than inferred.
#
# `sameAddress()` comparing equal at runtime is already evidence, but it is
# NEGATIVE evidence: it proves two addresses matched, and a compiler that
# emitted two globals which the linker later merged would also match. So the
# module is inspected directly -- the bytes of "shared" must appear under
# exactly ONE global. Byte-identical globals are not unnamed_addr (ADR-0040),
# so a second one would survive to the object and this would catch it.
# ---------------------------------------------------------------------------
PROBE="$CORE_DIR/dcc/bin/_probe_str.dart"
cat > "$PROBE" <<'DART'
import 'package:backend/llvm_emit.dart';
import 'package:backend/targets.dart';
import 'package:dcc_lower/lower.dart';

Future<void> main(List<String> args) async {
  final module = await lowerToDCModule(
    args[0],
    preludeUri: Uri.file('${args[1]}/runtime/dc-core-bare/prelude.dart'),
  );
  final target = DCTarget.parse('bare-x86_64', hostOsName: 'linux', hostArchName: 'x64');
  for (final line in emitModule(module, targetTriple: target.triple,
      noRedZone: target.forbidsRedZone).split('\n')) {
    if (line.startsWith('@dc.str.')) print(line);
  }
}
DART
STR_GLOBALS="$(cd "$CORE_DIR" && dart dcc/bin/_probe_str.dart "$EXAMPLE_DIR/str.dart" "$CORE_DIR" 2>&1)"
rm -f "$PROBE"

# "shared" == 115 104 97 114 101 100
SHARED_PAT='i8 115, i8 104, i8 97, i8 114, i8 101, i8 100'
N_SHARED="$(grep -cF "$SHARED_PAT" <<<"$STR_GLOBALS")"
[[ "$N_SHARED" == "1" ]] \
  || fail "expected the bytes of \"shared\" under exactly ONE global, found $N_SHARED — identical literals must be interned. Globals emitted:
$STR_GLOBALS"

# And the guard against the opposite failure: interning must be by CONTENT,
# never by length or by some looser key. Five distinct literals are declared
# and "shared" is written twice, so exactly five globals must exist. Interning
# "hello" with "héllo" (both 5 source characters) would show up here.
N_GLOBALS="$(grep -c '^@dc\.str\.' <<<"$STR_GLOBALS")"
[[ "$N_GLOBALS" == "5" ]] \
  || fail "expected exactly 5 string globals for 5 distinct literals, found $N_GLOBALS — interning must key on exact BYTES. Globals emitted:
$STR_GLOBALS"

# The UTF-8 divergence, pinned in the emitted bytes as well as at runtime:
# "héllo" must be 6 i8 elements, not 5.
grep -qF '@dc.str.2 = internal constant [6 x i8]' <<<"$STR_GLOBALS" \
  || fail "\"héllo\" was not emitted as 6 bytes; a 5-element global means the literal was measured in UTF-16 code units. Got: $(grep '@dc.str.2' <<<"$STR_GLOBALS")"

echo "  interning ok: 5 globals for 5 distinct literals, \"shared\" interned to one, \"héllo\" is 6 bytes"

# ---------------------------------------------------------------------------
# Step 2 — BEHAVIOUR. Build for the host, link ordinarily, run.
#
# No Linux/x86-64 gate: this links against real libc like
# examples/demo-collatz does, so it runs natively on macOS, Linux and Windows.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host \
    str.dart -o "$WORKDIR/str_host.o" --emit-header "$WORKDIR/str.h" ) \
    >"$WORKDIR/hostbuild.log" 2>&1 \
  || { cat "$WORKDIR/hostbuild.log" >&2; fail "dcc build --target host failed"; }

[[ -f "$WORKDIR/str.h" ]] || fail "--emit-header produced no header"

clang -I"$WORKDIR" -o "$WORKDIR/str_test" "$EXAMPLE_DIR/main.c" \
  "$WORKDIR/str_host.o" >"$WORKDIR/link.log" 2>&1 \
  || { cat "$WORKDIR/link.log" >&2; fail "hosted link failed"; }

OUT="$("$WORKDIR/str_test")"; STATUS=$?
echo "$OUT"
[[ $STATUS -eq 0 ]] || fail "rodata_test exited $STATUS — a value read back wrong"
grep -q "STR: all correct" <<<"$OUT" || fail "unexpected output: $OUT"

echo "STR: PASS — literals live in .rodata, length is UTF-8 BYTES (6 for "héllo", not 5), bytes are walkable through .address, identical literals intern to one global while distinct ones do not, and dead literals cost zero bytes"
exit 0
