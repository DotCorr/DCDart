#!/usr/bin/env bash
# core/tests/conformance/ffi-extern/run.sh
#
# Mechanical check of docs/decisions/0038-extern-symbols-and-linking.md: the
# INBOUND half of DCDART_SPEC.md §9 -- DCDart calling a C-ABI symbol that is
# not defined in its own compilation unit, and linking several object files
# together.
#
# Six steps, each proving something the others cannot:
#
#   1. dcc emits an object with REAL undefined symbols and a manifest naming
#      exactly them.
#   2. verify-freestanding.sh PASSES that object, and says which externs it
#      honored (CLAUDE.md rule 1 is still mechanical, not waived).
#   3. THE SPINE TEST. With the manifest removed, the same object must FAIL
#      the same check. An undeclared undefined symbol is still fatal; that is
#      the whole difference between "rule 1 with a declared exception" and
#      "rule 1 abandoned". See docs/escalations/0003-extern-c-calls-vs-
#      freestanding.md, RATIFIED by the project owner (option 2), 2026-08-20.
#   4. FREESTANDING multi-object link (`-nostdlib`, no libc): the DCDart
#      object plus a companion C object plus an entry stub really link, and
#      the linked image has zero undefined symbols left. Run for real when
#      the host can execute x86-64 Linux binaries; link-verified otherwise
#      (m2-port's precedent for a target the host cannot execute).
#   5. NATIVE HOST link and REAL RUN of the same DCDart source: three objects
#      linked with plain clang, executed, exit code checked. This is the leg
#      that actually runs the extern calls on every supported host.
#   6. REAL LIBC: a second DCDart source calling ffs/toupper/putchar --
#      symbols nobody in this project wrote. Exit code AND the bytes putchar
#      left on stdout are both checked, so a constant-folded return value
#      cannot pass.
#
# Usage:
#   bash core/tests/conformance/ffi-extern/run.sh
#
# Exit status: 0 on PASS, 1 on FAIL, 2 on harness usage/setup error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
EXAMPLE_DIR="$CORE_DIR/examples/ffi-extern"
VERIFY_SCRIPT="$CORE_DIR/scripts/verify-freestanding.sh"
ALLOWLIST="$CORE_DIR/tools/bare-symbol-allowlist.txt"

fail() {
  echo "FFI-extern: FAIL — $1" >&2
  exit 1
}

setup_error() {
  echo "FFI-extern: FAIL — $1" >&2
  exit 2
}

for f in extern_calls.dart c_side.c main.c libc_calls.dart main_libc.c; do
  [[ -f "$EXAMPLE_DIR/$f" ]] || setup_error "missing target source $EXAMPLE_DIR/$f"
done
[[ -f "$VERIFY_SCRIPT" ]] || setup_error "missing $VERIFY_SCRIPT"
[[ -f "$ALLOWLIST" ]] || setup_error "allowlist not found at $ALLOWLIST"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-ffi-extern.XXXXXX")" || setup_error "could not create a temp workdir"
trap 'rm -rf "$WORKDIR"' EXIT

if command -v dcc >/dev/null 2>&1; then
  DCC_CMD=(dcc)
elif command -v dart >/dev/null 2>&1; then
  DCC_CMD=(dart "$CORE_DIR/dcc/bin/dcc.dart")
else
  fail "neither dcc nor dart found on PATH, see docs/known-gaps.md GAP-0001"
fi

command -v clang >/dev/null 2>&1 || fail "clang not found on PATH, see docs/known-gaps.md GAP-0001"
command -v llvm-nm >/dev/null 2>&1 || fail "llvm-nm not found on PATH (required by verify-freestanding.sh), see docs/known-gaps.md GAP-0001"

# The symbols extern_calls.dart declares. Kept here, spelled out, rather than
# read back out of the manifest -- a check that reads its own answer from the
# thing under test proves nothing.
EXPECTED_EXTERNS="dcx_add dcx_answer dcx_checked dcx_clamp8 dcx_mix32 dcx_record dcx_widen"

# ---------------------------------------------------------------------------
# Step 1 — dcc build (freestanding x86-64), real undefined symbols, manifest.
# ---------------------------------------------------------------------------
BARE_OBJ="$WORKDIR/extern_calls.o"
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target bare-x86_64 extern_calls.dart -o "$BARE_OBJ" )
[[ $? -eq 0 ]] || fail "'dcc build --mode bare --target bare-x86_64 extern_calls.dart' failed"
[[ -f "$BARE_OBJ" ]] || fail "dcc reported success but $BARE_OBJ was not produced"

MANIFEST="$BARE_OBJ.externs"
[[ -f "$MANIFEST" ]] || fail "dcc did not write the extern manifest $MANIFEST"

ACTUAL_UNDEF="$(llvm-nm -u --format=posix "$BARE_OBJ" | awk '{print $1}' | sed 's/^_//' | sort | tr '\n' ' ' | sed 's/ $//')"
EXPECTED_SORTED="$(printf '%s\n' $EXPECTED_EXTERNS | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "$ACTUAL_UNDEF" != "$EXPECTED_SORTED" ]]; then
  fail "undefined symbols in $BARE_OBJ are [$ACTUAL_UNDEF], expected exactly [$EXPECTED_SORTED]"
fi

MANIFEST_SYMS="$(grep -vE '^\s*(#|$)' "$MANIFEST" | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "$MANIFEST_SYMS" != "$EXPECTED_SORTED" ]]; then
  fail "manifest lists [$MANIFEST_SYMS], expected exactly [$EXPECTED_SORTED]"
fi
echo "FFI-extern: step 1 ok — 7 real undefined symbols, manifest agrees"

# ---------------------------------------------------------------------------
# Step 2 — the spine check must PASS, and must say what it honored.
# ---------------------------------------------------------------------------
VERIFY_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$BARE_OBJ" 2>&1)"
VERIFY_STATUS=$?
echo "$VERIFY_OUT"
if [[ $VERIFY_STATUS -ne 0 ]] || ! grep -q "FREESTANDING: pass" <<<"$VERIFY_OUT"; then
  fail "verify-freestanding.sh did not report a clean pass for $BARE_OBJ"
fi
grep -q "declared extern" <<<"$VERIFY_OUT" || \
  fail "verify-freestanding.sh passed but did not report the declared externs (escalation 0003's first condition)"

# ---------------------------------------------------------------------------
# Step 3 — THE SPINE TEST. Same object, manifest removed: must FAIL.
# ---------------------------------------------------------------------------
mv "$MANIFEST" "$WORKDIR/manifest.hidden" || setup_error "could not move the manifest aside"
NEG_OUT="$(DCDART_ALLOWLIST="$ALLOWLIST" bash "$VERIFY_SCRIPT" "$BARE_OBJ" 2>&1)"
NEG_STATUS=$?
mv "$WORKDIR/manifest.hidden" "$MANIFEST" || setup_error "could not restore the manifest"
if [[ $NEG_STATUS -eq 0 ]]; then
  echo "$NEG_OUT"
  fail "with its manifest removed, $BARE_OBJ still passed verify-freestanding.sh — an undeclared undefined symbol MUST be fatal (CLAUDE.md rule 1)"
fi
grep -q "FREESTANDING: FAIL" <<<"$NEG_OUT" || fail "manifest-removed run exited non-zero but did not report FREESTANDING: FAIL"
echo "FFI-extern: step 3 ok — undeclared undefined symbols are still a hard failure"

# ---------------------------------------------------------------------------
# Step 4 — FREESTANDING multi-object link (-nostdlib, no libc).
#
# This is the configuration oscortex_core needs, and the reason the companion
# c_side.c references no libc symbol of its own.
# ---------------------------------------------------------------------------
FS_DIR="$WORKDIR/fs"
mkdir -p "$FS_DIR"
FS_TARGET_FLAGS=(--target=x86_64-unknown-none-elf -ffreestanding -fno-builtin -fno-stack-protector)

clang "${FS_TARGET_FLAGS[@]}" -c "$EXAMPLE_DIR/c_side.c" -o "$FS_DIR/c_side.o" || fail "freestanding compile of c_side.c failed"
clang "${FS_TARGET_FLAGS[@]}" -c "$EXAMPLE_DIR/main.c" -o "$FS_DIR/main.o" || fail "freestanding compile of main.c failed"

cat > "$FS_DIR/_start.S" <<'EOF'
    .text
    .global _start
_start:
    call    main
    movl    %eax, %edi
    movl    $60, %eax
    syscall
EOF
clang --target=x86_64-unknown-none-elf -c "$FS_DIR/_start.S" -o "$FS_DIR/start.o" || fail "assembling the entry stub failed"

FS_BIN="$FS_DIR/ffi_extern_fs"
FS_LINKER=""
HOST_OS="$(uname -s 2>/dev/null || echo unknown)"
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
if [[ "$HOST_OS" == Linux* ]]; then
  # Same link line the other conformance harnesses use.
  if clang -ffreestanding -fno-builtin -nostdlib -static -o "$FS_BIN" \
      "$FS_DIR/start.o" "$FS_DIR/main.o" "$FS_DIR/c_side.o" "$BARE_OBJ" >"$FS_DIR/link.log" 2>&1; then
    FS_LINKER="clang -nostdlib"
  fi
fi
if [[ -z "$FS_LINKER" ]] && command -v x86_64-elf-ld >/dev/null 2>&1; then
  # Apple's ld cannot link ELF; x86_64-elf-ld (brew install x86_64-elf-binutils)
  # can, which is what makes this leg real rather than skipped on macOS.
  if x86_64-elf-ld -o "$FS_BIN" \
      "$FS_DIR/start.o" "$FS_DIR/main.o" "$FS_DIR/c_side.o" "$BARE_OBJ" >>"$FS_DIR/link.log" 2>&1; then
    FS_LINKER="x86_64-elf-ld"
  fi
fi
if [[ -z "$FS_LINKER" ]]; then
  cat "$FS_DIR/link.log" >&2 2>/dev/null
  fail "no ELF linker available for the freestanding leg (need a Linux clang or x86_64-elf-ld); see docs/known-gaps.md GAP-0048"
fi
[[ -f "$FS_BIN" ]] || fail "$FS_LINKER reported success but $FS_BIN was not produced"

# Zero undefined symbols in the LINKED image: every relocation dcc emitted
# for an extern call really resolved against c_side.o.
LEFTOVER="$(llvm-nm -u --format=posix "$FS_BIN" 2>/dev/null | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')"
[[ -z "$LEFTOVER" ]] || fail "linked freestanding image still has undefined symbols: [$LEFTOVER]"
echo "FFI-extern: step 4 ok — freestanding link via $FS_LINKER, all relocations resolved"

# Run it for real where the host can. Not a skip-and-pretend: step 5 executes
# the identical DCDart source natively on every supported host, so the extern
# calls are always really executed somewhere in this harness.
FS_RAN="no"
if [[ "$HOST_OS" == Linux* && ( "$HOST_ARCH" == x86_64 || "$HOST_ARCH" == amd64 ) ]]; then
  "$FS_BIN"; FS_STATUS=$?
  [[ $FS_STATUS -eq 0 ]] || fail "freestanding ffi_extern_fs exited $FS_STATUS — see core/examples/ffi-extern/main.c for what each code means"
  FS_RAN="natively"
elif command -v qemu-x86_64 >/dev/null 2>&1; then
  qemu-x86_64 "$FS_BIN"; FS_STATUS=$?
  [[ $FS_STATUS -eq 0 ]] || fail "freestanding ffi_extern_fs exited $FS_STATUS under qemu-x86_64"
  FS_RAN="under qemu-x86_64"
fi
if [[ "$FS_RAN" == "no" ]]; then
  FS_RAN="link-verified only (host cannot execute it)"
  echo "FFI-extern: step 4 note — freestanding image LINK-verified only on this host"
  echo "  ($HOST_OS/$HOST_ARCH cannot execute an x86-64 Linux binary, and no qemu-x86_64"
  echo "   is on PATH). Step 5 runs the identical DCDart source natively."
else
  echo "FFI-extern: step 4 ok — freestanding image ran $FS_RAN, exit 0"
fi

# ---------------------------------------------------------------------------
# Step 5 — NATIVE HOST: three objects linked with plain clang, really run.
# ---------------------------------------------------------------------------
HOST_OBJ="$WORKDIR/extern_calls_host.o"
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host extern_calls.dart -o "$HOST_OBJ" )
[[ $? -eq 0 ]] || fail "'dcc build --mode bare --target host extern_calls.dart' failed"

clang -c "$EXAMPLE_DIR/c_side.c" -o "$WORKDIR/c_side_host.o" || fail "native compile of c_side.c failed"
clang -c "$EXAMPLE_DIR/main.c" -o "$WORKDIR/main_host.o" || fail "native compile of main.c failed"
clang -o "$WORKDIR/ffi_extern_host" "$WORKDIR/main_host.o" "$WORKDIR/c_side_host.o" "$HOST_OBJ" \
  || fail "native link of main.o + c_side.o + dcc's object failed"

"$WORKDIR/ffi_extern_host"
HOST_STATUS=$?
[[ $HOST_STATUS -eq 0 ]] || fail "ffi_extern_host exited $HOST_STATUS — see core/examples/ffi-extern/main.c for what each code means"
echo "FFI-extern: step 5 ok — native 3-object link, real execution, exit 0"

# ---------------------------------------------------------------------------
# Step 6 — REAL LIBC. Symbols nobody in this project wrote.
# ---------------------------------------------------------------------------
LIBC_OBJ="$WORKDIR/libc_calls.o"
( cd "$EXAMPLE_DIR" && "${DCC_CMD[@]}" build --mode bare --target host libc_calls.dart -o "$LIBC_OBJ" )
[[ $? -eq 0 ]] || fail "'dcc build --mode bare --target host libc_calls.dart' failed"

LIBC_MANIFEST="$LIBC_OBJ.externs"
[[ -f "$LIBC_MANIFEST" ]] || fail "dcc did not write an extern manifest for libc_calls.dart"
for sym in ffs toupper putchar; do
  grep -qx "$sym" "$LIBC_MANIFEST" || fail "libc manifest is missing \"$sym\""
done

clang -c "$EXAMPLE_DIR/main_libc.c" -o "$WORKDIR/main_libc.o" || fail "native compile of main_libc.c failed"
clang -o "$WORKDIR/ffi_extern_libc" "$WORKDIR/main_libc.o" "$LIBC_OBJ" \
  || fail "native link of main_libc.o + dcc's object against libc failed"

LIBC_OUT="$("$WORKDIR/ffi_extern_libc")"
LIBC_STATUS=$?
[[ $LIBC_STATUS -eq 0 ]] || fail "ffi_extern_libc exited $LIBC_STATUS — see core/examples/ffi-extern/main_libc.c for what each code means"
# putchar's side effect really left the process. 'DCDART\n' -- the trailing
# newline is eaten by $( ), so compare against the six visible characters.
[[ "$LIBC_OUT" == "DCDART" ]] || fail "putchar wrote [$LIBC_OUT] to stdout, expected [DCDART]"
echo "FFI-extern: step 6 ok — real libc (ffs/toupper/putchar), exit 0, stdout [$LIBC_OUT]"

echo "FFI-extern: PASS — dcc emits real undefined symbols -> verify-freestanding distinguishes declared externs from leaks (and still fails on an undeclared one) -> freestanding multi-object link ($FS_LINKER, ran $FS_RAN) -> native 3-object link and real execution -> real libc calls with a checked side effect"
exit 0
