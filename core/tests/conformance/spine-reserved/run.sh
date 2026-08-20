#!/usr/bin/env bash
# core/tests/conformance/spine-reserved/run.sh
#
# Guards the one property of the spine check that a manifest must never be
# able to override: RESERVED runtime symbol families are always a hard
# failure, whether or not an extern manifest declares them.
#
# WHY THIS EXISTS
#
# ADR-0038 taught scripts/verify-freestanding.sh to permit symbols the author
# declared with `@extern external`, recorded in <objfile>.externs. Escalation
# 0003's ratified wording was explicit that this keeps "catching dc_alloc,
# dc_throw, dc_orc_* and Dart_* exactly as before", and the script's own
# header says those families are "still a hard failure, always".
#
# It was not true. A manifest listing `dc_alloc` or `Dart_EnterScope` made the
# check print `FREESTANDING: pass`. That is the difference between a spine and
# a spine with an escape hatch: every other undefined symbol is a claim about
# SOMEONE ELSE'S object, which an author may legitimately make, but these four
# families are claims about our OWN runtime — they appear because the compiler
# emitted them, which is why their diagnostics say "This is a backend bug.
# Escalate to E2 immediately." No legitimate program calls Dart_EnterScope.
#
# This harness pins the fixed behaviour. It uses hand-built C objects rather
# than DCDart source ON PURPOSE: DCDart cannot currently emit a call to
# dc_alloc at all, so the only way to test the checker's response to one is to
# construct the object directly. This tests the CHECKER, not the compiler.
#
# Usage:
#   bash core/tests/conformance/spine-reserved/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
VERIFY="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() { echo "SPINE-RESERVED: FAIL — $1" >&2; exit 1; }
setup_error() { echo "SPINE-RESERVED: FAIL — $1" >&2; exit 2; }

[[ -f "$VERIFY" ]] || setup_error "missing $VERIFY"
[[ -f "$ALLOWLIST" ]] || setup_error "missing $ALLOWLIST"
command -v clang >/dev/null 2>&1 || fail "clang not found on PATH"
command -v llvm-nm >/dev/null 2>&1 || fail "llvm-nm not found on PATH (verify-freestanding.sh needs it)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-spine-reserved.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

run_check() { DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY" "$1" 2>&1; }

# ---------------------------------------------------------------------------
# Step 1 — an object referencing reserved runtime symbols.
# ---------------------------------------------------------------------------
cat > "$WORKDIR/rt.c" <<'EOF'
extern void *dc_alloc(unsigned long);
extern void dc_throw(void);
extern void Dart_EnterScope(void);
void *g(unsigned long n){ dc_throw(); Dart_EnterScope(); return dc_alloc(n); }
EOF
clang --target=x86_64-unknown-none-elf -ffreestanding -fno-builtin -c \
  "$WORKDIR/rt.c" -o "$WORKDIR/rt.o" 2>"$WORKDIR/cc.log" \
  || { cat "$WORKDIR/cc.log" >&2; fail "could not build the reserved-symbol fixture"; }

# ---------------------------------------------------------------------------
# Step 2 — with NO manifest it must fail. (Baseline: if this ever passes, the
# checker is broken in a much more basic way than this harness is about.)
# ---------------------------------------------------------------------------
out="$(run_check "$WORKDIR/rt.o")"; status=$?
if [[ $status -eq 0 ]]; then
  echo "$out" >&2
  fail "reserved symbols passed with no manifest at all — the baseline check is broken"
fi
echo "SPINE-RESERVED: step 2 ok — reserved symbols fail with no manifest"

# ---------------------------------------------------------------------------
# Step 3 — THE REGRESSION. With a manifest declaring every one of them, it
# must STILL fail. This is the case that used to pass.
# ---------------------------------------------------------------------------
printf 'dc_alloc\ndc_throw\nDart_EnterScope\n' > "$WORKDIR/rt.o.externs"
out="$(run_check "$WORKDIR/rt.o")"; status=$?
if [[ $status -eq 0 ]]; then
  echo "$out" >&2
  fail "a manifest declaring dc_alloc/dc_throw/Dart_EnterScope made the spine check PASS. Reserved runtime families must never be honorable — see escalation 0003 and this script's header."
fi
grep -q 'RESERVED runtime name' <<<"$out" \
  || fail "reserved symbols failed, but the output does not explain that declaring them cannot help. The diagnostic is the point: got: $out"
echo "SPINE-RESERVED: step 3 ok — a manifest cannot honor a reserved runtime symbol"

# ---------------------------------------------------------------------------
# Step 4 — the legitimate case must be UNAFFECTED. Without this, "harden the
# check" could just mean "break the feature", and the harness would not know.
# ---------------------------------------------------------------------------
cat > "$WORKDIR/ok.c" <<'EOF'
extern int some_real_c_library_function(int);
int h(int a){ return some_real_c_library_function(a) + 1; }
EOF
clang --target=x86_64-unknown-none-elf -ffreestanding -fno-builtin -c \
  "$WORKDIR/ok.c" -o "$WORKDIR/ok.o" 2>/dev/null \
  || fail "could not build the legitimate-extern fixture"

out="$(run_check "$WORKDIR/ok.o")"; status=$?
if [[ $status -eq 0 ]]; then
  fail "an UNDECLARED ordinary symbol passed. The check must still fail anything not declared."
fi
printf 'some_real_c_library_function\n' > "$WORKDIR/ok.o.externs"
out="$(run_check "$WORKDIR/ok.o")"; status=$?
if [[ $status -ne 0 ]]; then
  echo "$out" >&2
  fail "a legitimately declared extern was rejected — the hardening broke ADR-0038's feature"
fi
grep -q 'declared extern' <<<"$out" \
  || fail "declared externs are not reported on a pass (escalation 0003 condition 1). Got: $out"
echo "SPINE-RESERVED: step 4 ok — ordinary externs still honored and reported, undeclared ones still rejected"

echo "SPINE-RESERVED: PASS — reserved runtime families are unhonorable by manifest; ordinary externs unaffected"
exit 0
