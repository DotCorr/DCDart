#!/usr/bin/env bash
# core/tests/conformance/closure-capture-reject/run.sh
#
# NEGATIVE conformance target: a CAPTURING closure is REJECTED, with a
# diagnostic that names the reason, not a generic "unsupported".
#
# WHY A TEST ASSERTS A MISSING FEATURE. Escalation 0008 §2: the capture
# convention (by value / strong / weak-unowned, and the `[weak self]`-shaped
# syntax CLAUDE.md's cycle rule needs) is an ARC convention, which rule 4
# freezes at M3 -- it must be DECIDED by a human, not landed by default
# inside some other unit. ADR-0057 therefore rejects capture deliberately,
# and ADR-0060 (function values, GAP-0052) was built NOT to answer it. This
# target pins that state:
#
#   * If capture starts COMPILING, this target fails -- loudly, at the
#     moment it happens, naming what must follow: a recorded decision on
#     0008 §2, and a rewrite of bench/benchmarks/closure-heavy/ in capture
#     syntax (its manifest says so) so the M3 gate measures the real
#     lowering rather than the explicit-environment spelling.
#   * If the DIAGNOSTIC degrades to a generic error, this target fails too:
#     the rejection's whole value is that it tells the user what is missing
#     and where the record is (probed 2026-08-27 -- the message names
#     ADR-0057, the captured variable, and escalation 0008).
#
# Three shapes, because they fail for three reasons that could regress
# independently: a captured scalar, a captured heap object, and a capturing
# function torn off as a value (the ADR-0060 path).
#
# Usage:
#   bash core/tests/conformance/closure-capture-reject/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

fail() { echo "CLOSURE-CAPTURE-REJECT: FAIL — $1" >&2; exit 1; }
setup_error() { echo "CLOSURE-CAPTURE-REJECT: FAIL — $1" >&2; exit 2; }

if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  setup_error "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-capture-reject.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

# Each fixture must (a) FAIL to build, (b) with a diagnostic that names the
# captured variable and points at the record (ADR-0057 and escalation 0008).
check_rejected() {
  local src="$1" var="$2"
  local log="$WORKDIR/$(basename "$src").log"
  if ( cd "$SCRIPT_DIR" && "${DCC_CMD[@]}" build --mode bare --target host \
        "$src" -o "$WORKDIR/$(basename "$src").o" ) >"$log" 2>&1; then
    fail "$src COMPILED. A capturing closure landed without escalation 0008 §2 being decided -- or was decided and this target was not updated. Either way, STOP: (1) confirm a recorded decision exists for the capture convention (docs/escalations/0008 §2, CLAUDE.md rule 4); (2) rewrite bench/benchmarks/closure-heavy/ in capture syntax and re-measure (its manifest requires this); (3) replace this negative target with a positive capture conformance target."
  fi
  grep -q "captures \"$var\"" "$log" \
    || fail "$src was rejected but the diagnostic no longer names the captured variable \"$var\" — got:
$(cat "$log")"
  grep -q "ADR-0057" "$log" \
    || fail "$src's diagnostic no longer cites ADR-0057 — got:
$(cat "$log")"
  grep -q "0008" "$log" \
    || fail "$src's diagnostic no longer points at escalation 0008 — got:
$(cat "$log")"
  echo "  rejected with the recorded diagnostic: $(basename "$src") (captures \"$var\")"
}

check_rejected "$SCRIPT_DIR/capture_scalar.dart"   "k"
check_rejected "$SCRIPT_DIR/capture_heap.dart"     "b"
check_rejected "$SCRIPT_DIR/capture_as_value.dart" "k"

echo "CLOSURE-CAPTURE-REJECT: PASS — capturing closures are still rejected with the ADR-0057 diagnostic (escalation 0008 §2 remains a decision, not an accident); the day this fails on \"COMPILED\" is the day closure-heavy gets rewritten in capture syntax"
