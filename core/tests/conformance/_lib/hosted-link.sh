# core/tests/conformance/_lib/hosted-link.sh
#
# Portable "link the object under test and run it" step, shared by every
# behavioural conformance harness. Sourced, not executed.
#
# WHY THIS EXISTS (GAP-0048)
#
# The M0/M1/M2 harnesses linked with `-nostdlib` plus a hand-written `_start`
# that issues the x86-64 Linux `sys_exit` syscall. That stub is Linux/x86-64
# ABI by construction, so on a macOS or Windows dev host those harnesses did
# not skip -- they FAILED, and 17 of them failed together. A language whose
# stated goal is running natively on macOS, Windows and Linux could not run
# its own conformance suite on two of the three.
#
# WHAT IS AND IS NOT GIVEN UP ON THE PORTABLE PATH
#
# The `-nostdlib` link demonstrated something real: that the object needs no
# crt, no libc, no dynamic loader. On the hosted path that link-level evidence
# is NOT reproduced -- the binary is linked against real libc like any other
# program.
#
# It is not lost, because it was never the only evidence. Every one of these
# harnesses independently runs `verify-freestanding.sh` over the `--mode bare
# --target bare-x86_64` object BEFORE reaching this step, and that check --
# `nm -u` against the allowlist, CLAUDE.md rule 1, the project's spine -- is
# target-independent and runs identically on all three hosts. It is also the
# STRONGER of the two: a `-nostdlib` link that happened to succeed because the
# linker resolved a symbol from a static archive would pass the link while
# failing `nm -u`. The freestanding guarantee is asserted where it was always
# asserted; what changes here is only how the behaviour gets executed.
#
# So both paths are kept rather than one replaced: Linux/x86-64 still takes
# the `-nostdlib` path and keeps the belt-and-braces link evidence, and every
# other host takes the hosted path and keeps the behavioural assertion. The
# harness prints which one ran, so a pass is never ambiguous about what it
# proved.
#
# USAGE
#
#   source "$CORE_DIR/tests/conformance/_lib/hosted-link.sh"
#   dc_link_and_run_setup            # requires WORKDIR, DCC_CMD, EXAMPLE_DIR
#   dc_link "$BIN" "$MAIN_C" "$BARE_OBJ" "$SRC_DART" [extra clang args...]
#   # -> sets DC_LINK_MODE to "freestanding" or "hosted"
#
# Callers must define `fail` before sourcing. On the hosted path the source
# file is REBUILT for `--target host`, because the bare-x86_64 object is ELF
# and will not link into a Mach-O or PE image.

# Decide once, so every harness in a run reports the same mode.
dc_link_mode() {
  local os arch
  os="$(uname -s 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$os/$arch" in
    Linux*/x86_64|Linux*/amd64) echo freestanding ;;
    *) echo hosted ;;
  esac
}

# dc_link <out_bin> <main.c> <bare_obj> <src.dart> [extra clang args...]
dc_link() {
  local bin="$1" main_c="$2" bare_obj="$3" src_dart="$4"; shift 4
  DC_LINK_MODE="$(dc_link_mode)"

  [[ -n "${WORKDIR:-}" ]] || fail "dc_link: WORKDIR is unset (harness bug)"
  [[ -f "$main_c" ]] || fail "dc_link: missing $main_c"
  command -v clang >/dev/null 2>&1 || fail "clang not found on PATH, see docs/known-gaps.md GAP-0001"

  if [[ "$DC_LINK_MODE" == "freestanding" ]]; then
    cat > "$WORKDIR/_start.S" <<'ASM'
/* Minimal freestanding entry point, harness-only. Not part of the object
 * under test, whose freestanding guarantee is checked separately by
 * verify-freestanding.sh before this file is ever written. */
    .text
    .global _start
_start:
    call    main
    movl    %eax, %edi     /* main's return value -> exit_code arg */
    movl    $60, %eax      /* x86-64 Linux sys_exit */
    syscall
ASM
    clang -ffreestanding -fno-builtin -nostdlib -static \
      -o "$bin" "$WORKDIR/_start.S" "$main_c" "$bare_obj" "$@" \
      >"$WORKDIR/link.log" 2>&1 \
      || { cat "$WORKDIR/link.log" >&2; fail "freestanding link failed (log above)"; }
  else
    [[ -f "$src_dart" ]] || fail "dc_link: missing $src_dart (needed to rebuild for --target host)"
    [[ ${#DCC_CMD[@]} -gt 0 ]] || fail "dc_link: DCC_CMD is unset (harness bug)"
    local host_obj="$WORKDIR/_hosted_$(basename "${src_dart%.dart}").o"
    ( cd "$(dirname "$src_dart")" && "${DCC_CMD[@]}" build --mode bare --target host \
        "$(basename "$src_dart")" -o "$host_obj" ) >"$WORKDIR/hostbuild.log" 2>&1 \
      || { cat "$WORKDIR/hostbuild.log" >&2; fail "dcc build --target host failed (log above)"; }
    clang -o "$bin" "$main_c" "$host_obj" "$@" >"$WORKDIR/link.log" 2>&1 \
      || { cat "$WORKDIR/link.log" >&2; fail "hosted link failed (log above)"; }
  fi

  [[ -f "$bin" ]] || fail "clang reported success but $bin was not produced"
}
