#!/usr/bin/env bash
# core/tests/conformance/void-release/run.sh
#
# Conformance target for scope releases on the IMPLICIT return path — the
# void-function leak NEON N1's tensor library found (2026-08-27).
#
# What this target exists to prove: `_lowerReturn` releases tracked heap/
# weak locals and `@owned` params on an explicit `return`, but a void
# function that falls off the end takes `_lowerBody`'s synthesized
# `Return()` instead, and that path emitted no releases — so `void
# dropBox(@owned Box b) {}` (a consuming release whose empty body IS the
# operation) leaked every argument. No prior target had a void function
# that tracked anything, which is why 43 green targets missed it.
#
# The harness churns thousands of objects through three void shapes (empty
# @owned body / fresh local falling off the end / alias + if-else merge
# falling through) and asserts dc_heap_live == 0 after every call — the
# same leak-test discipline as m2-owned, aimed at the OTHER return path.
#
# Usage:
#   bash core/tests/conformance/void-release/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-void-release"

fail() { echo "VOIDRELEASE: FAIL — $1" >&2; exit 1; }
setup_error() { echo "VOIDRELEASE: FAIL — $1" >&2; exit 2; }

[[ -f "$EXAMPLE_DIR/voidrelease.dart" ]] || setup_error "missing $EXAMPLE_DIR/voidrelease.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing $EXAMPLE_DIR/main.c"

if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi
command -v clang >/dev/null 2>&1 || fail "clang not found on PATH"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-voidrelease.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host \
    voidrelease.dart -o "$WORKDIR/voidrelease.o" --emit-header "$WORKDIR/voidrelease.h" ) \
    >"$WORKDIR/build.log" 2>&1 \
  || { cat "$WORKDIR/build.log" >&2; fail "dcc build --target host failed"; }

clang -I"$WORKDIR" -o "$WORKDIR/voidrelease_test" "$EXAMPLE_DIR/main.c" \
  "$WORKDIR/voidrelease.o" >"$WORKDIR/link.log" 2>&1 \
  || { cat "$WORKDIR/link.log" >&2; fail "hosted link failed"; }

OUT="$("$WORKDIR/voidrelease_test")"; STATUS=$?
echo "$OUT"
[[ $STATUS -eq 0 ]] || fail "voidrelease_test exited $STATUS — a void function leaked or miscomputed"
grep -q "VOIDRELEASE: all correct" <<<"$OUT" || fail "unexpected output: $OUT"

# ---------------------------------------------------------------------------
# ARC-count assertion (CLAUDE.md's elision-test rule for anything touching
# ARC codegen): the releases must exist AT THE DC-IR LEVEL, per function —
# the runtime check above could in principle be satisfied by a wrong-place
# release somewhere else. dc-objdump --arc is the same channel funcptr's
# harness uses.
# ---------------------------------------------------------------------------
ARC="$(cd "$CORE_DIR/dc-objdump" && dart bin/dc_objdump.dart --arc "$EXAMPLE_DIR/voidrelease.dart" 2>&1)" \
  || fail "dc-objdump --arc failed: $ARC"
grep -qE "dropBox: alloc=0 retain=0 release=1" <<<"$ARC" \
  || fail "dropBox must carry exactly the one @owned release on its implicit return (got: $(grep dropBox <<<"$ARC"))"
grep -qE "makeAndForget: alloc=1 retain=0 release=1" <<<"$ARC" \
  || fail "makeAndForget must release its local on the implicit return (got: $(grep makeAndForget <<<"$ARC"))"
# Post-ELISION counts: pre-elide inspectAndDrop is retain=1 release=2 (the
# ADR-0017 alias retain for `c` plus both scope releases), and dc-elide
# correctly cancels the alias pair ACROSS the implicit-return releases,
# leaving just the @owned release — asserted here so the elision behavior
# on this path is pinned too, not only the leak fix.
grep -qE "inspectAndDrop: alloc=0 retain=0 release=1" <<<"$ARC" \
  || fail "inspectAndDrop must elide the alias pair and keep the @owned release (got: $(grep inspectAndDrop <<<"$ARC"))"
ARC_RAW="$(cd "$CORE_DIR/dc-objdump" && dart bin/dc_objdump.dart --arc --no-elide "$EXAMPLE_DIR/voidrelease.dart" 2>&1)" \
  || fail "dc-objdump --arc --no-elide failed: $ARC_RAW"
grep -qE "inspectAndDrop: alloc=0 retain=1 release=2" <<<"$ARC_RAW" \
  || fail "pre-elide inspectAndDrop must carry the alias retain and BOTH implicit-return releases (got: $(grep inspectAndDrop <<<"$ARC_RAW"))"
echo "  arc counts ok: dropBox release=1, makeAndForget release=1, inspectAndDrop 1/2 pre-elide -> 0/1 elided — all on the implicit-return path"

echo "VOIDRELEASE: PASS — 3n objects churned through void @owned/local/merge shapes at n up to 1000, dc_heap_live back to zero after every call, DC-IR release counts asserted"
exit 0
