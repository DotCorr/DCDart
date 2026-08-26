# core/bench/tool/stats.awk
#
# Reads one nanosecond sample per line on stdin (in run order), writes
# KEY=VALUE lines.
#
# WHY THE ROBUST STATISTICS, since this was got wrong once and then fixed
# against real data rather than by taste. A benchmark's sample distribution on
# a laptop is a tight core plus a heavy RIGHT tail: 25 runs of `fib` came out
# as 45.96 .. 47.37 ms with one straggler at 49.97 ms. The straggler is another
# process getting the core, not the benchmark being slow.
#
#   * The MEAN is moved by that straggler. The MEDIAN is not.
#   * (P90 - P10) is also moved by it -- the first version of this file gated on
#     that and refused measurements whose medians reproduced to 0.01% across
#     independent runs. That is a false refusal, and a harness that cries wolf
#     gets its thresholds relaxed by the next person, which is worse than
#     having no threshold.
#   * (P75 - P25) -- the interquartile range -- describes the CORE and ignores
#     the tail, so it is what the noise gate uses.
#
# Both are reported. SPREAD stays visible because it is the honest picture of
# what the machine did; IQR is what decides.
#
#   N              number of samples
#   MEDIAN_NS      the reported time for this configuration
#   MIN_NS/MAX_NS/P10_NS/P25_NS/P75_NS/P90_NS
#   SPREAD_PCT     (P90 - P10) / median -- descriptive, tail-sensitive
#   IQR_PCT        (P75 - P25) / median -- the noise figure that is gated on
#   SEM_PCT        estimated relative uncertainty OF THE MEDIAN, derived from
#                  the IQR: sigma_hat = IQR / 1.349 (the IQR of a normal
#                  distribution is 1.349 sigma), and SE(median) = 1.2533 *
#                  sigma_hat / sqrt(n). So SEM_PCT = 0.9291 * IQR_PCT / sqrt(n).
#                  This is the number that propagates into a ratio.
#   HALF_DRIFT_PCT median of the first half of the samples vs median of the
#                  second half, IN RUN ORDER. An assumption-free check for
#                  drift during the measurement -- thermal throttling, a
#                  background job starting. No model can catch this; only
#                  looking can.
#   MEAN_NS/SD_PCT informational only. Nothing gates on them.
#
# awk has no sort. Insertion sort over a few dozen samples is instant and keeps
# this a single dependency-free file (macOS ships awk, not gawk; nothing here
# uses a GNU extension).

{ raw[n++] = $1 + 0 }

END {
    if (n == 0) { print "N=0"; exit 1 }

    for (i = 0; i < n; i++) v[i] = raw[i]
    isort(v, n)

    median = med_of(v, 0, n)
    p10 = v[rank(0.10, n)]
    p25 = v[rank(0.25, n)]
    p75 = v[rank(0.75, n)]
    p90 = v[rank(0.90, n)]

    sum = 0
    for (i = 0; i < n; i++) sum += v[i]
    mean = sum / n
    ss = 0
    for (i = 0; i < n; i++) ss += (v[i] - mean) * (v[i] - mean)
    sd = (n > 1) ? sqrt(ss / (n - 1)) : 0

    spread_pct = (median > 0) ? (p90 - p10) / median * 100 : 999
    iqr_pct    = (median > 0) ? (p75 - p25) / median * 100 : 999
    sem_pct    = 0.9291 * iqr_pct / sqrt(n)

    # Half-split drift, in RUN ORDER (raw[], not the sorted copy).
    h = int(n / 2)
    if (h >= 2) {
        for (i = 0; i < h; i++)      a[i] = raw[i]
        for (i = 0; i < n - h; i++)  b[i] = raw[h + i]
        isort(a, h); isort(b, n - h)
        ma = med_of(a, 0, h); mb = med_of(b, 0, n - h)
        lo = (ma < mb) ? ma : mb
        drift = (lo > 0) ? ((ma > mb) ? ma - mb : mb - ma) / lo * 100 : 999
    } else {
        drift = 0
    }

    printf "N=%d\n", n
    printf "MEDIAN_NS=%d\n", median
    printf "MIN_NS=%d\n", v[0]
    printf "MAX_NS=%d\n", v[n-1]
    printf "P10_NS=%d\n", p10
    printf "P25_NS=%d\n", p25
    printf "P75_NS=%d\n", p75
    printf "P90_NS=%d\n", p90
    printf "SPREAD_PCT=%.3f\n", spread_pct
    printf "IQR_PCT=%.3f\n", iqr_pct
    printf "SEM_PCT=%.3f\n", sem_pct
    printf "HALF_DRIFT_PCT=%.3f\n", drift
    printf "MEAN_NS=%d\n", mean
    printf "SD_PCT=%.3f\n", (mean > 0 ? sd / mean * 100 : 999)
}

function isort(arr, count,   i, j, key) {
    for (i = 1; i < count; i++) {
        key = arr[i]; j = i - 1
        while (j >= 0 && arr[j] > key) { arr[j+1] = arr[j]; j-- }
        arr[j+1] = key
    }
}

function med_of(arr, lo, count) {
    if (count % 2 == 1) return arr[lo + (count - 1) / 2]
    return (arr[lo + count/2 - 1] + arr[lo + count/2]) / 2
}

# Nearest-rank percentile, 1-based rank converted to a 0-based index.
function rank(p, count,   r) {
    r = int(p * count + 0.9999999)
    if (r < 1) r = 1
    if (r > count) r = count
    return r - 1
}
