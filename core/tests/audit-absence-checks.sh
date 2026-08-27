#!/usr/bin/env bash
# core/tests/audit-absence-checks.sh — find checks that can pass vacuously.
#
#   bash core/tests/audit-absence-checks.sh
#
# THE DEFECT IT LOOKS FOR. A check that concludes from the ABSENCE of a
# pattern passes on empty input. `llvm-objdump` that cannot read a format,
# a tool missing from PATH under `2>/dev/null`, a disassembly of an object
# that failed to build -- each yields nothing, and "nothing matched the bad
# pattern" then reads as "the bad pattern is not there."
#
# This is the shape that cost this project the most in a single day
# (2026-08-26/27): nine separate instances of a real mechanism, correctly
# implemented, verifying something ONE STEP AWAY from the claim it was
# trusted for. `pub get` succeeding rather than the compiler working. A
# disassembly grep on an empty disassembly. A golden regenerated from a
# non-deterministic capture. A conformance suite reporting a Linux
# container's number as the project's.
#
# WHAT MAKES IT EXPENSIVE, and why this script exists rather than a review
# checklist: several such checks FEEL independent -- different mechanisms,
# different files, different authors -- while sharing one upstream
# assumption. When that assumption is wrong they all fail in the same
# direction, and each one's agreement makes the others look confirmed.
# Checks that share an assumption are one check wearing several hats.
#
# HONEST LIMITS, stated so nobody over-reads a clean run:
#
#   * This is a HEURISTIC over shell text. It cannot know whether a guard is
#     adequate, only whether one appears nearby. Read every hit; some are
#     fine.
#   * A clean run does NOT mean the suite is free of adjacency defects. It
#     means no *textually detectable* absence-check lacks a nearby guard.
#     The nine instances found by hand were mostly NOT of this form -- they
#     were checks asserting the wrong thing, which no grep can see.
#   * The real instrument for this class is an EXPERIMENT THAT CANNOT SHARE
#     THE ASSUMPTION -- build it clean and run it -- not a sharper inspection.
#     Adjacency is broken by executing the claim, not by examining it harder.
#
# Exit status: always 0. This reports; it does not gate. A gate on a
# heuristic would itself become a check trusted for more than it establishes.

set -uo pipefail
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$CORE_DIR" || exit 2

echo "=== absence-check audit over tests/ and scripts/ ==="
echo

flagged=0
scanned=0

for f in tests/conformance/*/run.sh tests/*.sh scripts/*.sh; do
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  hits=""

  # An absence-concluding assertion: a `fail` fired by a pattern MATCHING
  # (grep -q X && fail) or a pass implied by a pattern NOT matching
  # (! grep / grep -qv). Both read a tool's output and treat "no match" as
  # good news.
  while IFS= read -r line; do
    n="${line%%:*}"
    txt="${line#*:}"
    case "$txt" in
      *'grep -qv'*|*'! grep'*|*'if grep -q'*|*'grep -q'*'&& fail'*) ;;
      *) continue ;;
    esac
    # Is there a non-emptiness guard within the preceding 25 lines? The
    # established idiom in this tree asserts the input has content first.
    start=$((n > 25 ? n - 25 : 1))
    if sed -n "${start},${n}p" "$f" | grep -qE 'VACUOUS|non-empty|no instructions|listed no|printed no|-z "\$|conclude from'; then
      continue
    fi
    hits="$hits    line $n: $(echo "$txt" | sed 's/^[[:space:]]*//' | cut -c1-88)
"
  done < <(grep -n -- '-q' "$f" 2>/dev/null)

  if [ -n "$hits" ]; then
    echo "  $f"
    printf '%s' "$hits"
    flagged=$((flagged + 1))
  fi
done

echo
echo "scanned $scanned files, flagged $flagged"
echo
echo "A flag is a QUESTION, not a defect: does this check still fail when the"
echo "thing it guards is broken, and have you SEEN it fail? If the answer is"
echo "'it has never been run against a broken input', that is the finding."
