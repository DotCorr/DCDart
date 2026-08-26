#!/usr/bin/env bash
# core/bench/run-bench.sh
#
# The M3 measurement harness. Builds and times each benchmark three ways --
# DCDart, C, and (optionally) stock Dart AOT -- and reports per-benchmark
# ratios and the GEOMETRIC mean vs C, which is the quantity ROADMAP.md M3's
# gate is stated in.
#
# It is written to REFUSE rather than to report. Every number below is guarded:
#
#   * the DCDart object it times must be byte-identical to `dcc build`'s
#   * every implementation of a benchmark must agree on its checksum
#   * every configuration must be quieter than --noise-max
#   * every ratio's propagated uncertainty must be under --ratio-unc-max
#   * the geometric mean is labelled as the M3 GATE NUMBER only when all five
#     of M3's required benchmarks are present, and today none of them are
#
# A harness that prints a number it cannot stand behind is worse than one that
# prints nothing, because the number outlives the caveat.
#
# Requires: bash (3.2 is fine -- no mapfile, no associative arrays), awk,
# clang, dart. Source dc_sys/env.sh (or core/scripts/dcdart-env.sh) first.

set -u

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
CORE_DIR="$(cd "$BENCH_DIR/.." && pwd)"
PKG_CONFIG="$CORE_DIR/dcc/.dart_tool/package_config.json"
DCC="$CORE_DIR/dcc/bin/dcc.dart"
DCBUILD="$BENCH_DIR/tool/dcbuild.dart"
STATS="$BENCH_DIR/tool/stats.awk"
DRIVER_SRC="$BENCH_DIR/harness/bench_main.c"

# ---------------------------------------------------------------------------
# Thresholds. Every one of these is a judgement call; README.md
# "Why the thresholds are what they are" shows the arithmetic behind each.
# ---------------------------------------------------------------------------

# Timed process runs per configuration. The FIRST is always discarded on top
# of this count, so RUNS=12 means 13 executions and 12 retained samples.
RUNS=12

# Noise limit, in percent, per configuration. Applied to the INTERQUARTILE
# range (P75-P25)/median and to the half-split drift, not to (P90-P10): see
# tool/stats.awk for why, with the data that made the difference.
NOISE_MAX=2.5

# Propagated relative uncertainty of a RATIO, in percent. This is the one that
# actually decides whether a 10% gate can be called.
RATIO_UNC_MAX=2.0

# A kernel shorter than this is dominated by timer resolution and the
# surrounding noise floor, whatever its spread happens to look like.
MIN_KERNEL_MS=25

REFCOUNT_MODES="nonatomic atomic"
WITH_DART_AOT=1
IDENTITY_CHECK=1
OUT_DIR=""
ONLY=""

# ROADMAP.md M3: "at minimum a JSON parser, a hashmap-heavy workload, a
# tree/graph traversal, a string-processing pass, and a closure-heavy
# functional workload". A benchmark directory claims one of these by setting
# BENCH_SUITE=m3 and BENCH_ID to the matching id.
M3_REQUIRED="json hashmap tree-traversal string-pass closure-heavy"

usage() {
    cat <<'EOF'
usage: run-bench.sh [options] [benchmark-id ...]

  --runs N              timed process runs per configuration (default 12;
                        one further run is always discarded as warmup)
  --noise-max PCT       per-configuration noise limit, applied to the
                        interquartile range and to half-split drift
                        (default 2.5)
  --ratio-unc-max PCT   per-ratio uncertainty limit (default 2.0)
  --min-kernel-ms MS    refuse kernels shorter than this (default 25)
  --refcount MODES      "nonatomic", "atomic", or "nonatomic atomic"
                        (default: both -- see README.md, this is required by
                        docs/escalations/0007 and docs/decisions/0053)
  --no-dart-aot         skip the stock Dart AOT column
  --no-identity-check   skip proving dcbuild.dart == dcc build (do not)
  --out DIR             results directory (default: a fresh mktemp -d)
  -h, --help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --runs) RUNS="$2"; shift 2 ;;
        --noise-max) NOISE_MAX="$2"; shift 2 ;;
        --ratio-unc-max) RATIO_UNC_MAX="$2"; shift 2 ;;
        --min-kernel-ms) MIN_KERNEL_MS="$2"; shift 2 ;;
        --refcount) REFCOUNT_MODES="$2"; shift 2 ;;
        --no-dart-aot) WITH_DART_AOT=0; shift ;;
        --no-identity-check) IDENTITY_CHECK=0; shift ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "run-bench.sh: unknown option $1" >&2; usage >&2; exit 64 ;;
        *) ONLY="$ONLY $1"; shift ;;
    esac
done

if [ -z "$OUT_DIR" ]; then
    OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dcdart-bench.XXXXXX")"
fi
mkdir -p "$OUT_DIR/build" "$OUT_DIR/samples"
ROWS="$OUT_DIR/rows.tsv"
: > "$ROWS"
NOTES="$OUT_DIR/notes.txt"
: > "$NOTES"

note() { echo "$*" >> "$NOTES"; }

# Echo to the terminal AND into report.txt, so the build-phase verdicts
# (identity check, ARC site counts, refcount-mode invariant) survive in the
# saved report instead of only in scrollback.
say()  { echo "$*"; echo "$*" >> "$OUT_DIR/report.txt"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

fail() { echo "run-bench.sh: $*" >&2; exit 2; }

command -v clang >/dev/null 2>&1 || fail "clang not on PATH"
command -v awk   >/dev/null 2>&1 || fail "awk not on PATH"
command -v dart  >/dev/null 2>&1 || \
    fail "dart not on PATH -- source dc_sys/env.sh (or core/scripts/dcdart-env.sh) first"
[ -f "$PKG_CONFIG" ] || fail "no $PKG_CONFIG -- run 'dart pub get' in core/dcc first
(if another session is mid-'pub get', wait 60s and retry; see core/docs/testing-setup.md §8)"
[ -f "$STATS" ] || fail "missing $STATS"
[ -f "$DRIVER_SRC" ] || fail "missing $DRIVER_SRC"

# ---------------------------------------------------------------------------
# Header: host, CPU, both compilers, both flag sets. Printed BEFORE any
# measurement, because a timing number without them is not reproducible and
# not comparable to any other machine's.
# ---------------------------------------------------------------------------

HOST_OS="$(uname -s)"
HOST_REL="$(uname -r)"
HOST_ARCH="$(uname -m)"
HOST_NAME="$(uname -n)"
if [ "$HOST_OS" = "Darwin" ]; then
    CPU_BRAND="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
    CPU_NCPU="$(sysctl -n hw.ncpu 2>/dev/null || echo ?)"
    CPU_PERF="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo ?)"
    CPU_EFF="$(sysctl -n hw.perflevel1.physicalcpu 2>/dev/null || echo 0)"
    CPU_TOPO="$CPU_NCPU logical ($CPU_PERF performance + $CPU_EFF efficiency cores)"
    OS_PRETTY="macOS $(sw_vers -productVersion 2>/dev/null || echo ?) ($HOST_OS $HOST_REL)"
else
    CPU_BRAND="$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)"
    CPU_TOPO="$(nproc 2>/dev/null || echo ?) logical"
    OS_PRETTY="$HOST_OS $HOST_REL"
fi

CLANG_VER="$(clang --version 2>/dev/null | head -1)"
CLANG_PATH="$(command -v clang)"
DART_VER="$(dart --version 2>&1 | head -1)"
DART_PATH="$(command -v dart)"
DCDART_REV="$(cd "$CORE_DIR" && git rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout')"
DCDART_DIRTY=""
if (cd "$CORE_DIR" && git diff --quiet 2>/dev/null); then :; else DCDART_DIRTY=" (working tree MODIFIED)"; fi

DC_FLAGS="$(dart --packages="$PKG_CONFIG" "$DCBUILD" --print-flags --target host 2>/dev/null)"
[ -n "$DC_FLAGS" ] || fail "could not read DCDart's clang flags from dcbuild.dart
(this usually means another session is mid-edit in backend/ or dcc-lower/;
core/docs/testing-setup.md §8 -- wait 60s and retry)"

DRIVER_FLAGS="-O2 -c"
LINK_FLAGS="(none: plain 'clang -o <bin> bench_main.o kernel.o'; no -flto on either side)"

print_header() {
cat <<EOF
=============================================================================
DCDart M3 benchmark harness
=============================================================================
date              : $(date -u '+%Y-%m-%dT%H:%M:%SZ') (UTC)
host              : $HOST_NAME
os                : $OS_PRETTY
arch              : $HOST_ARCH
cpu               : $CPU_BRAND
cpu topology      : $CPU_TOPO
dcdart rev        : $DCDART_REV$DCDART_DIRTY
results dir       : $OUT_DIR

compilers
  clang           : $CLANG_VER
                    $CLANG_PATH
  dart            : $DART_VER
                    $DART_PATH

COMPILER FLAGS -- these are EQUAL on both sides by construction, not by
intention. The DCDart list is transcribed in bench/tool/dcbuild.dart from
backend/lib/compile.dart, and that transcription is proved on every run by
rebuilding through 'dcc build' and requiring a byte-identical object file.
The SAME list is then applied to the C kernel.

  DCDart .ll -> .o : $DC_FLAGS -c
  C kernel   -> .o : $DC_FLAGS -c -std=c11
  timing driver    : clang $DRIVER_FLAGS   (identical for every side; hosted,
                     so no -ffreestanding; not part of any measured kernel)
  link             : $LINK_FLAGS

METHODOLOGY
  runs            : $RUNS timed process runs per configuration, plus one
                    discarded warmup process run, plus one discarded warmup
                    iteration inside every process
  statistic       : median of the $RUNS samples
                    noise      = interquartile range (P75-P25) / median
                    half-drift = median of first half vs second half, in run
                                 order (catches thermal throttling mid-run)
                    spread     = (P90-P10)/median, reported but not gated on
  refuse if       : noise > ${NOISE_MAX}% for any configuration
                    half-drift > ${NOISE_MAX}% for any configuration
                    ratio uncertainty > ${RATIO_UNC_MAX}%
                    median kernel time < ${MIN_KERNEL_MS} ms
                    any two implementations disagree on the checksum
                    (ratio uncertainty folds in the measured between-batch
                     drift of the C baseline as a systematic floor, so the
                     model can never claim more precision than the machine
                     demonstrated)
  refcount modes  : $REFCOUNT_MODES
=============================================================================
EOF
}

print_header | tee "$OUT_DIR/report.txt"

# ---------------------------------------------------------------------------
# Shared timing driver, built once. Identical object linked into every binary.
# ---------------------------------------------------------------------------

DRIVER_OBJ="$OUT_DIR/build/bench_main.o"
clang $DRIVER_FLAGS "$DRIVER_SRC" -o "$DRIVER_OBJ" || fail "could not build $DRIVER_SRC"

# ---------------------------------------------------------------------------
# Benchmark discovery
# ---------------------------------------------------------------------------

BENCHES=""
for d in "$BENCH_DIR"/benchmarks/*/; do
    [ -f "$d/manifest.sh" ] || continue
    id="$(basename "$d")"
    if [ -n "$ONLY" ]; then
        case " $ONLY " in *" $id "*) ;; *) continue ;; esac
    fi
    BENCHES="$BENCHES $id"
done
[ -n "$BENCHES" ] || fail "no benchmarks found under $BENCH_DIR/benchmarks/"

# ---------------------------------------------------------------------------
# time_binary <bin> <arg> <samples-out> ; echoes the checksum, or "" on failure
# ---------------------------------------------------------------------------

time_binary() {
    tb_bin="$1"; tb_arg="$2"; tb_out="$3"
    : > "$tb_out"
    tb_ck=""

    # Discarded warmup PROCESS run: cold dyld, cold pages, first-touch faults.
    if ! "$tb_bin" "$tb_arg" 1 >/dev/null 2>&1; then
        echo ""
        return 1
    fi

    tb_i=0
    while [ "$tb_i" -lt "$RUNS" ]; do
        tb_raw="$("$tb_bin" "$tb_arg" 1 2>/dev/null)" || { echo ""; return 1; }
        echo "$tb_raw" | awk '/^SAMPLE_NS /{print $2}' >> "$tb_out"
        tb_this="$(echo "$tb_raw" | awk '/^CHECKSUM /{print $2}')"
        if [ -z "$tb_ck" ]; then
            tb_ck="$tb_this"
        elif [ "$tb_ck" != "$tb_this" ]; then
            echo ""
            return 1
        fi
        tb_i=$((tb_i + 1))
    done
    echo "$tb_ck"
    return 0
}

# record <bench> <suite> <side> <mode> <samplefile> <checksum>
record() {
    r_bench="$1"; r_suite="$2"; r_side="$3"; r_mode="$4"; r_file="$5"; r_ck="$6"
    r_stats="$(awk -f "$STATS" < "$r_file")"
    r_n=$(echo "$r_stats"      | awk -F= '/^N=/{print $2}')
    r_med=$(echo "$r_stats"    | awk -F= '/^MEDIAN_NS=/{print $2}')
    r_spread=$(echo "$r_stats" | awk -F= '/^SPREAD_PCT=/{print $2}')
    r_iqr=$(echo "$r_stats"    | awk -F= '/^IQR_PCT=/{print $2}')
    r_sem=$(echo "$r_stats"    | awk -F= '/^SEM_PCT=/{print $2}')
    r_drift=$(echo "$r_stats"  | awk -F= '/^HALF_DRIFT_PCT=/{print $2}')
    r_min=$(echo "$r_stats"    | awk -F= '/^MIN_NS=/{print $2}')
    r_max=$(echo "$r_stats"    | awk -F= '/^MAX_NS=/{print $2}')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$r_bench" "$r_suite" "$r_side" "$r_mode" \
        "$r_n" "$r_med" "$r_spread" "$r_iqr" "$r_sem" "$r_drift" \
        "$r_min:$r_max" "$r_ck" >> "$ROWS"
}

# A benchmark that failed to build or run still gets a ROW, marked FAILED.
# Without it the benchmark simply vanishes from rows.tsv and the report happily
# computes a geometric mean over "the benchmarks that worked" -- a different
# and quieter quantity than the one asked for. Silent narrowing of a suite is
# exactly the failure this harness exists to prevent.
record_failed() {
    printf '%s\t%s\t%s\t%s\t0\t0\t0\t0\t0\t0\t-\t-\n' \
        "$1" "$2" "FAILED" "-" >> "$ROWS"
}

# ---------------------------------------------------------------------------
# Environment stability precheck. Two independent batches of the SAME binary
# must agree. This catches the failure mode a within-batch spread cannot: a
# machine that is internally consistent for ten seconds and then throttles.
# ---------------------------------------------------------------------------

STABILITY_STATUS="not run"
stability_check() {
    sc_bin="$1"; sc_arg="$2"
    sc_a="$OUT_DIR/samples/_stability_a.txt"
    sc_b="$OUT_DIR/samples/_stability_b.txt"
    time_binary "$sc_bin" "$sc_arg" "$sc_a" >/dev/null || return 1
    time_binary "$sc_bin" "$sc_arg" "$sc_b" >/dev/null || return 1
    sc_ma="$(awk -f "$STATS" < "$sc_a" | awk -F= '/^MEDIAN_NS=/{print $2}')"
    sc_mb="$(awk -f "$STATS" < "$sc_b" | awk -F= '/^MEDIAN_NS=/{print $2}')"
    sc_drift="$(awk -v a="$sc_ma" -v b="$sc_mb" \
        'BEGIN{ d=(a>b)?a-b:b-a; m=(a<b)?a:b; printf "%.3f", (m>0)? d/m*100 : 999 }')"
    STABILITY_STATUS="$sc_drift"
    return 0
}

# ---------------------------------------------------------------------------
# Build + time each benchmark
# ---------------------------------------------------------------------------

FATAL=0
STABILITY_DONE=0

for id in $BENCHES; do
    bd="$BENCH_DIR/benchmarks/$id"
    BENCH_ID=""; BENCH_DESC=""; BENCH_SUITE=""; BENCH_ARG=""; BENCH_NOTE=""
    . "$bd/manifest.sh"
    obd="$OUT_DIR/build/$id"
    mkdir -p "$obd"

    say ""
    say "--- $id ($BENCH_DESC) ---"

    # --- C baseline -------------------------------------------------------
    if ! clang $DC_FLAGS -std=c11 -c "$bd/kernel.c" -o "$obd/kernel.o" 2>"$obd/c.err"; then
        say "  C kernel FAILED to build:"; sed 's/^/    /' "$obd/c.err"
        note "$id: C baseline failed to build -- benchmark skipped entirely."
        record_failed "$id" "$BENCH_SUITE"; FATAL=1; continue
    fi
    clang -o "$obd/c" "$DRIVER_OBJ" "$obd/kernel.o" || {
        note "$id: C baseline failed to link."
        record_failed "$id" "$BENCH_SUITE"; FATAL=1; continue; }

    # --- Optional semantics-matched C baseline ----------------------------
    # C with DCDart's trapping arithmetic. Diagnostic only: it lets the report
    # ATTRIBUTE a gap to trap checks instead of leaving the reader to guess.
    # Never the gate baseline -- see bench/harness/trapping.h.
    HAVE_CTRAP=0
    if [ -f "$bd/kernel_trapck.c" ]; then
        if clang $DC_FLAGS -std=c11 -I"$BENCH_DIR/harness" \
                -c "$bd/kernel_trapck.c" -o "$obd/kernel_trapck.o" 2>"$obd/ctrap.err"; then
            clang -o "$obd/ctrap" "$DRIVER_OBJ" "$obd/kernel_trapck.o" && HAVE_CTRAP=1
        else
            say "  trap-matched C baseline FAILED to build:"; sed 's/^/    /' "$obd/ctrap.err"
        fi
    fi

    # --- DCDart, one object per refcount mode -----------------------------
    DC_OK=1
    for mode in $REFCOUNT_MODES; do
        if ! dart --packages="$PKG_CONFIG" "$DCBUILD" \
                --refcount="$mode" --target host \
                -o "$obd/bench.$mode.o" --emit-ll "$obd/bench.$mode.ll" \
                "$bd/bench.dart" > "$obd/dcbuild.$mode.out" 2>"$obd/dcbuild.$mode.err"; then
            say "  DCDart ($mode) FAILED to build:"
            sed 's/^/    /' "$obd/dcbuild.$mode.err"
            note "$id: DCDart build failed in $mode mode -- see $obd/dcbuild.$mode.err"
            DC_OK=0; break
        fi
        clang -o "$obd/dcdart.$mode" "$DRIVER_OBJ" "$obd/bench.$mode.o" || { DC_OK=0; break; }
    done
    if [ "$DC_OK" = 0 ]; then record_failed "$id" "$BENCH_SUITE"; FATAL=1; continue; fi

    ARC_SITES="$(awk -F= '/^DCBUILD_ARC_SITES=/{print $2}' "$obd/dcbuild.nonatomic.out" 2>/dev/null)"
    [ -n "$ARC_SITES" ] || ARC_SITES="$(awk -F= '/^DCBUILD_ARC_SITES=/{print $2}' "$obd/dcbuild.atomic.out" 2>/dev/null)"
    ARC_REWRITES="$(awk -F= '/^DCBUILD_ATOMIC_REWRITES=/{print $2}' "$obd/dcbuild.atomic.out" 2>/dev/null)"
    say "  ARC update sites in DC-IR: ${ARC_SITES:-?}   atomic rewrites applied: ${ARC_REWRITES:-n/a}"

    # --- Fairness proof: our object must BE dcc's object ------------------
    if [ "$IDENTITY_CHECK" = 1 ]; then
        case " $REFCOUNT_MODES " in *" nonatomic "*)
            if dart "$DCC" build --mode bare --target host "$bd/bench.dart" \
                   -o "$obd/bench.dcc.o" >"$obd/dcc.err" 2>&1; then
                if cmp -s "$obd/bench.dcc.o" "$obd/bench.nonatomic.o"; then
                    say "  identity check: PASS (dcbuild --refcount=nonatomic == dcc build, byte-identical)"
                else
                    say "  identity check: *** FAIL *** dcbuild's object differs from dcc build's."
                    note "$id: IDENTITY CHECK FAILED. bench/tool/dcbuild.dart no longer reproduces
    'dcc build' byte-for-byte, so the DCDart side of this benchmark is not the
    compiler the project ships and its ratio is meaningless. Most likely cause:
    backend/lib/compile.dart's flag list changed and dcdartClangFlags() in
    bench/tool/dcbuild.dart was not updated. Fix that before believing any number."
                    FATAL=1
                fi
            else
                say "  identity check: SKIPPED (dcc build failed -- see $obd/dcc.err)"
                note "$id: identity check could not run; 'dcc build' itself failed."
            fi
        ;; esac
    fi

    # --- Stock Dart AOT (optional, informational) -------------------------
    AOT_BIN=""
    if [ "$WITH_DART_AOT" = 1 ] && [ -f "$bd/bench_aot.dart" ]; then
        if dart compile exe "$bd/bench_aot.dart" -o "$obd/dartaot" \
               >"$obd/aot.err" 2>&1; then
            AOT_BIN="$obd/dartaot"
        else
            say "  stock Dart AOT: unavailable (see $obd/aot.err)"
        fi
    fi

    # --- Stability precheck, once, on the first C baseline built ----------
    if [ "$STABILITY_DONE" = 0 ]; then
        echo "  environment stability precheck (two independent batches of the C baseline)..."
        stability_check "$obd/c" "$BENCH_ARG" || note "stability precheck could not run"
        say "    between-batch median drift: ${STABILITY_STATUS}%"
        STABILITY_DONE=1
    fi

    # --- Time everything --------------------------------------------------
    echo "  timing..."
    ck_c="$(time_binary "$obd/c" "$BENCH_ARG" "$OUT_DIR/samples/$id.c.txt")"
    if [ -z "$ck_c" ]; then
        note "$id: C baseline did not run cleanly (non-deterministic or crashed)."
        record_failed "$id" "$BENCH_SUITE"; FATAL=1; continue
    fi
    record "$id" "$BENCH_SUITE" "c" "-" "$OUT_DIR/samples/$id.c.txt" "$ck_c"

    if [ "$HAVE_CTRAP" = 1 ]; then
        ck_t="$(time_binary "$obd/ctrap" "$BENCH_ARG" "$OUT_DIR/samples/$id.ctrap.txt")"
        if [ -z "$ck_t" ]; then
            note "$id: trap-matched C baseline did not run cleanly; attribution omitted."
        elif [ "$ck_t" != "$ck_c" ]; then
            note "$id: trap-matched C baseline checksum ($ck_t) != C ($ck_c); attribution omitted."
            FATAL=1
        else
            record "$id" "$BENCH_SUITE" "ctrap" "-" "$OUT_DIR/samples/$id.ctrap.txt" "$ck_t"
        fi
    fi

    for mode in $REFCOUNT_MODES; do
        ck="$(time_binary "$obd/dcdart.$mode" "$BENCH_ARG" "$OUT_DIR/samples/$id.dcdart.$mode.txt")"
        if [ -z "$ck" ]; then
            note "$id: DCDart ($mode) did not run cleanly."
            record_failed "$id" "$BENCH_SUITE"; FATAL=1; continue
        fi
        if [ "$ck" != "$ck_c" ]; then
            note "$id: CHECKSUM MISMATCH -- C says $ck_c, DCDart ($mode) says $ck.
    The two programs do not compute the same thing, so their times are not
    comparable. Refusing to report a ratio for this benchmark."
            FATAL=1
        fi
        record "$id" "$BENCH_SUITE" "dcdart" "$mode" \
            "$OUT_DIR/samples/$id.dcdart.$mode.txt" "$ck"
    done

    if [ -n "$AOT_BIN" ]; then
        ck_a="$(time_binary "$AOT_BIN" "$BENCH_ARG" "$OUT_DIR/samples/$id.dartaot.txt")"
        if [ -z "$ck_a" ]; then
            note "$id: stock Dart AOT did not run cleanly; column omitted."
        else
            if [ "$ck_a" != "$ck_c" ]; then
                note "$id: stock Dart AOT checksum ($ck_a) != C ($ck_c); column omitted."
            else
                record "$id" "$BENCH_SUITE" "dartaot" "-" \
                    "$OUT_DIR/samples/$id.dartaot.txt" "$ck_a"
            fi
        fi
    fi

    # --- Self-test invariant: no ARC => the two modes cannot differ -------
    if [ "${ARC_SITES:-0}" = "0" ] && [ "$BENCH_SUITE" = "selftest" ]; then
        # NOTE the spaces inside the patterns: `*"atomic"*` also matches
        # "nonatomic", which made this check run (and fail on a missing file)
        # when only the non-atomic mode was requested.
        case " $REFCOUNT_MODES " in *" nonatomic "*) case " $REFCOUNT_MODES " in *" atomic "*)
            if cmp -s "$obd/bench.nonatomic.o" "$obd/bench.atomic.o"; then
                say "  refcount-mode invariant: PASS (0 ARC sites => identical objects)"
            else
                say "  refcount-mode invariant: *** FAIL ***"
                note "$id: has 0 ARC update sites but its nonatomic and atomic objects
    differ. The atomic rewrite touched something that is not a refcount. Every
    atomic-mode number in this run is suspect."
                FATAL=1
            fi
        ;; esac ;; esac
    fi
done

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

REPORT_TAIL="$OUT_DIR/report.tail"

awk -F'\t' \
    -v noise_max="$NOISE_MAX" \
    -v unc_max="$RATIO_UNC_MAX" \
    -v min_ms="$MIN_KERNEL_MS" \
    -v modes="$REFCOUNT_MODES" \
    -v m3req="$M3_REQUIRED" \
    -v stability="$STABILITY_STATUS" \
    -v fatal="$FATAL" \
    -v notes_file="$NOTES" \
    -f "$BENCH_DIR/tool/report.awk" "$ROWS" | tee "$REPORT_TAIL"

cat "$REPORT_TAIL" >> "$OUT_DIR/report.txt"
rm -f "$REPORT_TAIL"

echo ""
echo "full report + raw samples: $OUT_DIR"

# Exit 3 means "this run did not produce a number the harness stands behind".
# That includes the M3 suite being incomplete, which it is and will remain until
# five benchmarks exist -- so 3 is the EXPECTED exit code today, and 0 will not
# be reachable before the gate is actually evaluable. 2 is a setup error.
if grep -q 'REFUSED\|\*\*\*' "$OUT_DIR/report.txt" || [ "$FATAL" != 0 ]; then
    exit 3
fi
exit 0
