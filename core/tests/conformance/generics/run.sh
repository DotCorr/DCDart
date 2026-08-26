#!/usr/bin/env bash
# core/tests/conformance/generics/run.sh
#
# Conformance target for monomorphized generics (ADR-0052).
#
# Asserts that a generic emits ONE SPECIALIZATION PER DISTINCT TYPE ARGUMENT
# and no template -- checked by reading the symbol table, not inferred from
# the values, because "it computed the right answer" is also true of a wrong
# implementation that emitted one shared body.
#
# `firstOfSecond` is the case worth having: a generic calling another generic,
# where the inner call's type argument is itself the outer's type parameter.
#
# Usage:
#   bash core/tests/conformance/generics/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-generics"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "GENERICS: FAIL — $1" >&2; exit 1; }
setup_error() { echo "GENERICS: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/generics.dart" ]] || setup_error "missing $EXAMPLE_DIR/generics.dart"
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

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-generics.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# ---------------------------------------------------------------------------
# Step 1 — build for the FREESTANDING target and check the spine.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 \
    generics.dart -o "$WORKDIR/generics.o" ) >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target bare-x86_64 failed"; }

if command -v llvm-nm >/dev/null 2>&1; then
  VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$WORKDIR/generics.o" 2>&1)"
  echo "$VERIFY_OUT"
  grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT" \
    || fail "static data introduced an undefined symbol — a DEFINED global must never do that"
else
  fail "llvm-nm not found on PATH (required by verify-freestanding.sh)"
fi

# ---------------------------------------------------------------------------
# Step 1b — SPECIALIZATION. One symbol per distinct type argument, and no
# symbol for the template itself. Read from the symbol table rather than
# inferred from behaviour: a wrong implementation that emitted a single shared
# body would still compute the right answers here.
# ---------------------------------------------------------------------------
if command -v llvm-nm >/dev/null 2>&1; then
  SYMS="$(llvm-nm "$WORKDIR/generics.o" 2>/dev/null)"
  [[ -n "$SYMS" ]] || fail "llvm-nm produced no symbols; the checks below would pass vacuously"
  for want in 'pick\$u64' 'pick\$u32' 'pick\$u8' 'second\$u64' 'firstOfSecond\$u64'; do
    grep -q "$want" <<<"$SYMS" \
      || fail "expected a specialization symbol matching \"$want\"; got: $(tr '\n' ' ' <<<"$SYMS")"
  done
  # The TEMPLATE must not be emitted: a bare `pick` with no type suffix would
  # mean something lowered `T` as if it had a machine representation.
  if grep -qE '[[:space:]]_?pick$' <<<"$SYMS"; then
    fail "an unspecialized template symbol 'pick' was emitted; a generic has no machine representation"
  fi
  echo "  specialization ok: pick\$u64/u32/u8, second\$u64, firstOfSecond\$u64, and no bare template"
fi

# ---------------------------------------------------------------------------
# Step 2 — BEHAVIOUR. Build for the host, link ordinarily, run.
#
# No Linux/x86-64 gate: this links against real libc like
# examples/demo-collatz does, so it runs natively on macOS, Linux and Windows.
# ---------------------------------------------------------------------------
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host \
    generics.dart -o "$WORKDIR/generics_host.o" --emit-header "$WORKDIR/generics.h" ) \
    >"$WORKDIR/hostbuild.log" 2>&1 \
  || { cat "$WORKDIR/hostbuild.log" >&2; fail "dcc build --target host failed"; }

[[ -f "$WORKDIR/generics.h" ]] || fail "--emit-header produced no header"

clang -I"$WORKDIR" -o "$WORKDIR/generics_test" "$EXAMPLE_DIR/main.c" \
  "$WORKDIR/generics_host.o" >"$WORKDIR/link.log" 2>&1 \
  || { cat "$WORKDIR/link.log" >&2; fail "hosted link failed"; }

OUT="$("$WORKDIR/generics_test")"; STATUS=$?
echo "$OUT"
[[ $STATUS -eq 0 ]] || fail "rodata_test exited $STATUS — a value read back wrong"
grep -q "GENERICS: all correct" <<<"$OUT" || fail "unexpected output: $OUT"

echo "GENERICS: PASS — one specialization per distinct type argument, no template symbol emitted, correct values including a generic calling another generic"
exit 0
