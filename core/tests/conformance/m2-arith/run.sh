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
# freestanding link, run-and-check-exit-code), including the identical
# Linux/x86-64 gate on the freestanding link. Step 3 is new and is the reason
# this harness is not a straight copy: `*` traps on overflow and `~/`/`%` trap
# on a zero divisor, and a trap KILLS the process, so those paths physically
# cannot be checked by main.c's exit code -- they need their own binary and
# their own assertion ("was killed by a signal"), which is what step 3 is.
#
# Step 3 is placed BEFORE the freestanding link rather than after it on
# purpose. It builds with `--target host` and links against the host libc, so
# it runs on any host with a working clang -- including the macOS/arm64 dev
# machines where step 4's Linux/x86-64-only entry stub correctly refuses. Put
# last, it would be dead code on exactly the hosts where it is the only
# execution-based evidence available. It is NOT a substitute for step 4 and
# does not let this harness report PASS without it.
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
# against the host libc so this step is executable on any clang host, not
# just the Linux/x86-64 one step 4 requires.
#
# The assertion is "died by signal", never "exited with code N": the exact
# signal is a backend/platform choice (SIGTRAP on this project's targets
# today, so 128+5 = 133, but SIGILL/SIGABRT would be an equally valid way to
# implement a trap and must not fail this check). Bash reports a
# signal-killed child as 128+signum, so 129..159 is exactly the set of
# "killed by a signal" statuses and nothing else. A trap that stopped
# trapping returns 40..45 from trap_divzero.c and lands outside that range,
# which is the regression this step exists to catch.
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
# Step 4 — link main.c against arith.o, freestanding. Same Linux/x86-64-only
# entry stub as the other conformance harnesses (GAP-0005).
# ---------------------------------------------------------------------------
HOST_OS="$(uname -s 2>/dev/null || echo unknown)"
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
case "$HOST_OS" in
  Linux*) ;;
  *) fail "this harness's freestanding entry stub is Linux/x86-64 only (host reported '$HOST_OS'); see docs/known-gaps.md GAP-0005" ;;
esac
case "$HOST_ARCH" in
  x86_64|amd64) ;;
  *) fail "this harness's freestanding entry stub is Linux/x86-64 only (host reported '$HOST_ARCH'); see docs/known-gaps.md GAP-0005" ;;
esac

cat > "$WORKDIR/_start.S" <<'EOF'
    .text
    .global _start
_start:
    call    main
    movl    %eax, %edi
    movl    $60, %eax
    syscall
EOF

LINK_LOG="$WORKDIR/link.log"
clang -ffreestanding -fno-builtin -nostdlib -static \
  -o "$BIN" "$WORKDIR/_start.S" "$EXAMPLE_DIR/main.c" "$OBJ" \
  >"$LINK_LOG" 2>&1
LINK_STATUS=$?
if [[ $LINK_STATUS -ne 0 ]]; then
  cat "$LINK_LOG" >&2
  fail "freestanding link of main.c + arith.o exited $LINK_STATUS (log above)"
fi
[[ -f "$BIN" ]] || fail "clang reported success but $BIN was not produced"

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

echo "M2-ARITH: PASS -- dcc build -> verify-freestanding pass -> trap check (~/ 0, % 0, * overflow all killed by signal) -> freestanding link -> real execution, * at u64/u32/u16/u8 and ~/ and % at u64/u32/u8 swept over ranges, gcd/digitSum/isPrime/powMod/lcm/sumProperDivisors composed against hard-coded answers, all correct"
exit 0
