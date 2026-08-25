#!/usr/bin/env bash
# core/tests/conformance/m2-arith/run.sh
#
# Mechanical check of docs/decisions/0035-complete-integer-operators.md's `*`
# and docs/decisions/0036-division-and-remainder.md's `~/` and `%`, for
# u8/u16/u32/u64. Like m2-bitwise (and unlike m2-port) these are unprivileged
# instructions -- real execution and an exact expected-value check, the
# strongest form this project's harnesses use.
#
# Structure is m2-bitwise/run.sh's, with ONE step added. Steps 1, 2, 4 and 5
# are that harness's steps 1-4 verbatim in shape (build, verify-freestanding,
# link, run-and-check-exit-code), including the identical use of the shared
# link helper. Step 3 is new and is the reason this harness is not a straight
# copy: `*` traps on overflow and `~/`/`%` trap on a zero divisor, and a trap
# KILLS the process, so those paths physically cannot be checked by main.c's
# exit code -- they need their own binary and their own assertion ("was
# killed by a signal"), which is what step 3 is.
#
# Step 3 is placed BEFORE the link-and-run step rather than after it on
# purpose. It builds with `--target host` and links against the host libc, so
# it runs on any host with a working clang. It is the only execution-based
# evidence for the trapping paths, and ordering it first keeps it from being
# skipped by an early failure in the link step. It is NOT a substitute for
# steps 4-5 and does not let this harness report PASS without them.
#
# Usage:
#   bash core/tests/conformance/m2-arith/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/m2-arith"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() {
  echo "M2-ARITH: FAIL -- $1" >&2
  exit 1
}

setup_error() {
  echo "M2-ARITH: FAIL -- $1" >&2
  exit 2
}

[[ -f "$EXAMPLE_DIR/arith.dart" ]] || setup_error "missing target source $EXAMPLE_DIR/arith.dart"
[[ -f "$EXAMPLE_DIR/main.c" ]] || setup_error "missing target harness $EXAMPLE_DIR/main.c"
[[ -f "$EXAMPLE_DIR/trap_divzero.c" ]] || setup_error "missing trap harness $EXAMPLE_DIR/trap_divzero.c"
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-m2-arith.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

OBJ="$WORKDIR/arith.o"
HOST_OBJ="$WORKDIR/arith_host.o"
TRAP_BIN="$WORKDIR/arith_trap"
BIN="$WORKDIR/arith_test"

# ---------------------------------------------------------------------------
# Step 1 — dcc build --mode bare arith.dart -o arith.o
# ---------------------------------------------------------------------------
if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare arith.dart -o "$OBJ" )
DCC_STATUS=$?
if [[ $DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare arith.dart -o arith.o' exited $DCC_STATUS"
fi
[[ -f "$OBJ" ]] || fail "dcc reported success but $OBJ was not produced"

# ---------------------------------------------------------------------------
# Step 2 — verify-freestanding.sh arith.o must report a clean pass.
# ---------------------------------------------------------------------------
if ! command -v llvm-nm >/dev/null 2>&1; then
  fail "llvm-nm not found on PATH (required by verify-freestanding.sh), see docs/known-gaps.md GAP-0001"
fi
[[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"

VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$OBJ" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
if [[ $VERIFY_STATUS -ne 0 ]] || ! grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass for $OBJ"
fi

# ---------------------------------------------------------------------------
# Step 3 — trap verification. `~/ 0`, `% 0` and an overflowing `*` must each
# KILL the process (ADR-0035, ADR-0036). Built with --target host and linked
# against the host libc so this step is executable on any clang host.
#
# The assertion is "died by signal", never "exited with code N": the exact
# signal is a backend/platform choice, and it genuinely differs by host.
# `llvm.trap` lowers per target:
#
#   Linux/x86-64   -> `ud2`  -> SIGILL  (4)  -> bash reports 132
#   macOS/arm64    -> `brk`  -> SIGTRAP (5)  -> bash reports 133
#
# Both are correct implementations of "this operation traps", so pinning
# this check to either number would make the harness fail on the other host
# for no real reason. SIGABRT (6) via a libc `abort()` lowering would be an
# equally valid third answer. Bash reports a signal-killed child as
# 128+signum, so 129..159 is exactly the set of "killed by a signal"
# statuses and nothing else.
#
# This is NOT "any nonzero exit". The two regressions this step exists to
# catch both land squarely OUTSIDE 129..159 and still fail: a trap that
# became a normal exit, and an operation that silently returned a wrong
# value instead of trapping, both return trap_divzero.c's own 40..45 codes.
# ---------------------------------------------------------------------------
if ! command -v clang >/dev/null 2>&1; then
  fail "clang not found on PATH, see docs/known-gaps.md GAP-0001"
fi

( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host arith.dart -o "$HOST_OBJ" )
HOST_DCC_STATUS=$?
if [[ $HOST_DCC_STATUS -ne 0 ]]; then
  fail "'dcc build --mode bare --target host arith.dart' exited $HOST_DCC_STATUS (needed by the trap check)"
fi
[[ -f "$HOST_OBJ" ]] || fail "dcc reported success but $HOST_OBJ was not produced"

HOST_VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$HOST_OBJ" 2>&1)"
HOST_VERIFY_STATUS=$?
echo "$HOST_VERIFY_OUT"
if [[ $HOST_VERIFY_STATUS -ne 0 ]] || ! grep -q "FREESTANDING: pass" <<<"$HOST_VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass for the --target host object $HOST_OBJ"
fi

TRAP_LINK_LOG="$WORKDIR/trap-link.log"
clang -o "$TRAP_BIN" "$EXAMPLE_DIR/trap_divzero.c" "$HOST_OBJ" >"$TRAP_LINK_LOG" 2>&1
TRAP_LINK_STATUS=$?
if [[ $TRAP_LINK_STATUS -ne 0 ]]; then
  cat "$TRAP_LINK_LOG" >&2
  fail "hosted link of trap_divzero.c + arith_host.o exited $TRAP_LINK_STATUS (log above)"
fi
[[ -x "$TRAP_BIN" ]] || fail "clang reported success but $TRAP_BIN was not produced"

# trap_divzero.c selects its trap by argc: 1 arg-count = `~/ 0`, 2 = `% 0`,
# 3+ = overflowing `*`.
#
# The death is EXPECTED, so bash's own "Trace/BPT trap: 5" announcement is
# noise. Silencing it needs the shape below, not a plain redirect: that
# message is written by the shell that WAITED on the process, not by the
# process, so `cmd 2>/dev/null` never suppresses it. The subshell does the
# waiting here, and the `2>/dev/null` on the subshell is what catches the
# message; the trailing `exit $?` is load-bearing too -- without a second
# command inside the parens bash execs the binary in the subshell directly,
# the parent does the waiting again, and the message comes back.
check_trap() {
  local label="$1"
  shift
  ( "$TRAP_BIN" "$@" >/dev/null 2>&1; exit $? ) 2>/dev/null
  local status=$?
  if [[ $status -lt 129 || $status -gt 159 ]]; then
    fail "$label did not trap: arith_trap exited $status, which is a normal return, not death by signal (bash reports a signal-killed child as 128+signum, i.e. 129..159). See core/examples/m2-arith/trap_divzero.c."
  fi
  echo "TRAP: pass  $label killed by signal $((status - 128))"
}

check_trap "divU64(1071, 0)  [~/ by zero]"
check_trap "remU64(1071, 0)  [% by zero]" a
check_trap "mulU64(2^63, 3)  [* overflow]" a b

# ---------------------------------------------------------------------------
# Step 4 — link main.c against arith.o and produce a runnable binary.
#
# On Linux/x86-64 this is still the freestanding link: -ffreestanding
# -fno-builtin -nostdlib -static, plus a hand-written `_start`, because
# -nostdlib means there is no crt0 and therefore nothing to call `main`.
# That link is belt-and-braces evidence that arith.o needs no crt, no libc
# and no dynamic loader.
#
# On every other host that `_start` cannot work -- it is x86-64 Linux
# `sys_exit` by construction -- so the shared helper rebuilds arith.dart for
# `--target host` and links it against libc instead. See
# tests/conformance/_lib/hosted-link.sh for exactly what that trades away;
# short version: nothing this harness relied on it for, because arith.o's
# freestanding guarantee is asserted in Step 2 above by
# verify-freestanding.sh (and again in Step 3 for the --target host object),
# which runs identically on every host and is the stronger of the two checks.
#
# This is GAP-0048 closed: this harness used to FAIL rather than skip on
# macOS and Windows, so it (and 16 sibling targets) could not run on two of
# the three hosts DCDart claims to support. $DC_LINK_MODE records which path
# ran and is printed in the PASS line, so a pass is never ambiguous about
# what it proved.
# ---------------------------------------------------------------------------
source "$CORE_DIR/tests/conformance/_lib/hosted-link.sh"
dc_link "$BIN" "$EXAMPLE_DIR/main.c" "$OBJ" "$EXAMPLE_DIR/arith.dart"

# ---------------------------------------------------------------------------
# Step 5 — run the binary, assert exit code 0. main.c's own checks: 1-4 = `*`
# at u64/u32/u16/u8 wrong, 5-6 = `~/`/`%` at u64 wrong, 7-8 = at u32, 9-10 =
# at u8, 11 = wide/near-limit products wrong, 12-13 = gcd at u64/u32, 14 =
# digitSum, 15 = isPrime, 16 = powMod, 17 = lcm, 18 = sumProperDivisors --
# see core/examples/m2-arith/main.c.
# ---------------------------------------------------------------------------
"$BIN"
ACTUAL=$?
if [[ $ACTUAL -ne 0 ]]; then
  fail "arith_test exited $ACTUAL -- see core/examples/m2-arith/main.c for what each code means"
fi

echo "M2-ARITH: PASS -- dcc build -> verify-freestanding pass -> trap check (~/ 0, % 0, * overflow all killed by signal) -> $DC_LINK_MODE link -> real execution, * at u64/u32/u16/u8 and ~/ and % at u64/u32/u8 swept over ranges, gcd/digitSum/isPrime/powMod/lcm/sumProperDivisors composed against hard-coded answers, all correct"
exit 0
