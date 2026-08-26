#!/usr/bin/env bash
# core/scripts/dcdart-env.sh -- put the DCDart toolchain on PATH for this shell.
#
#   source core/scripts/dcdart-env.sh
#
# Then `dcc`, `dart`, `clang` and `llvm-nm` all resolve, and
# `bash core/tests/run-conformance.sh` works.
#
# THE macOS TRAP THIS SCRIPT EXISTS TO AVOID, stated up front because it costs
# an hour and the error message points somewhere else entirely:
#
#   `verify-freestanding.sh` needs `llvm-nm`, which on a Mac ships inside
#   Xcode at Toolchains/XcodeDefault.xctoolchain/usr/bin. The obvious move is
#   to put that directory on PATH. DO NOT. It also contains a `clang` that
#   shadows /usr/bin/clang, and that clang has no macOS SDK sysroot wired in,
#   so every link fails with:
#
#       ld: library 'System' not found
#
#   which reads as a broken SDK rather than a shadowed compiler. This script
#   symlinks ONLY llvm-nm into its own bin directory and leaves the rest of
#   the Xcode toolchain off PATH.

_dcdart_die() { echo "dcdart-env: $1" >&2; return 1; }

DCDART_CORE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DCDART_CORE

# --- Dart SDK -------------------------------------------------------------
# Must be 3.12.2 to match the pinned frontend (ADR-0005). A different SDK will
# usually still run `dcc`, but the vendored front_end is pinned to that tag and
# a mismatch surfaces as confusing Kernel IR errors rather than a version
# complaint.
DCDART_REQUIRED_DART_MINOR=12   # 3.12.x -- the tag the frontend is pinned to

if [[ -n "${DCDART_DART_SDK:-}" ]]; then
  PATH="$DCDART_DART_SDK/bin:$PATH"
elif ! command -v dart >/dev/null 2>&1; then
  _dcdart_die "no \`dart\` on PATH and DCDART_DART_SDK is unset. Install Dart 3.12.2 (see docs/testing-setup.md) or point DCDART_DART_SDK at an SDK root."
fi
export PATH

# VERSION CHECK, and it earns its place: with an older SDK on PATH the build
# does not say "wrong Dart version". It emits ~4 KB of
#
#   pkg/kernel/lib/ast.dart:1:1: Error: The language version 3.12 specified for
#   the package 'kernel' is too high. The highest supported language version is 3.11.
#
# repeated once per file in the vendored frontend, which reads as a corrupted
# vendor tree and sends you to re-run vendor-frontend.sh, which fixes nothing.
# The diagnostic points at the symptom's location rather than the cause's, so
# this check names the cause once, before anything is built.
if command -v dart >/dev/null 2>&1; then
  _dcdart_ver="$(dart --version 2>&1 | sed -n 's/.*version: \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  _dcdart_major="${_dcdart_ver%%.*}"
  _dcdart_rest="${_dcdart_ver#*.}"
  _dcdart_minor="${_dcdart_rest%%.*}"
  if [[ -z "$_dcdart_ver" ]]; then
    echo "dcdart-env: WARNING -- could not parse \`dart --version\`; skipping the version check. If the build reports \"language version 3.12 ... is too high\", your SDK is too old." >&2
  elif [[ "$_dcdart_major" != "3" ]] || (( _dcdart_minor < DCDART_REQUIRED_DART_MINOR )); then
    echo "dcdart-env: WRONG DART VERSION -- found $_dcdart_ver at $(command -v dart), need 3.$DCDART_REQUIRED_DART_MINOR.x" >&2
    echo "            The vendored frontend is pinned to the 3.12.2 tag (ADR-0005). Building with an" >&2
    echo "            older SDK fails with thousands of \"language version 3.12 ... is too high\" errors" >&2
    echo "            pointing at core/frontend/vendor/, which looks like a corrupt vendor tree and is not." >&2
    echo "            Fix: DCDART_DART_SDK=/path/to/dart-sdk-3.12.2 source core/scripts/dcdart-env.sh" >&2
  fi
  unset _dcdart_ver _dcdart_major _dcdart_minor _dcdart_rest
fi

# --- LLVM binutils, without dragging Xcode's clang along ------------------
# llvm-nm backs verify-freestanding.sh (rule 1); llvm-objdump backs every
# harness that asserts on emitted INSTRUCTIONS rather than on results --
# m2-port, no-red-zone, rodata, volatile, str. Those are precisely the checks
# that catch what behavioural testing structurally cannot (GAP-0027), so a
# missing llvm-objdump silently removes the suite's best defects-detector.
_dcdart_shim="${DCDART_TOOLCHAIN_BIN:-$HOME/.dcdart/bin}"
for _tool in llvm-nm llvm-objdump; do
  command -v "$_tool" >/dev/null 2>&1 && continue
  if [[ ! -x "$_dcdart_shim/$_tool" ]]; then
    for _cand in \
      "/opt/homebrew/opt/llvm/bin/$_tool" \
      "/usr/local/opt/llvm/bin/$_tool" \
      "$(xcrun --find "$_tool" 2>/dev/null || true)"
    do
      if [[ -x "$_cand" ]]; then
        mkdir -p "$_dcdart_shim"
        ln -sf "$_cand" "$_dcdart_shim/$_tool"
        break
      fi
    done
  fi
done
[[ -d "$_dcdart_shim" ]] && PATH="$_dcdart_shim:$PATH"
unset _cand _tool _dcdart_shim

export PATH

# --- report, rather than assume -------------------------------------------
# A silent `source` that half-worked is how someone ends up debugging the
# compiler when the real problem is a missing tool.
_dcdart_ok=1
for _t in dart clang llvm-nm llvm-objdump; do
  if command -v "$_t" >/dev/null 2>&1; then
    printf '  %-9s %s\n' "$_t" "$(command -v "$_t")"
  else
    printf '  %-9s MISSING\n' "$_t"
    _dcdart_ok=0
  fi
done
if [[ "$_dcdart_ok" == "1" ]]; then
  echo "dcdart-env: ready. Try: bash \"$DCDART_CORE/tests/run-conformance.sh\""
else
  echo "dcdart-env: INCOMPLETE -- see core/docs/testing-setup.md. llvm-nm missing means verify-freestanding.sh cannot run, and CLAUDE.md rule 1 is unverifiable." >&2
fi
unset _dcdart_ok _t
