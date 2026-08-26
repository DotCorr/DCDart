# core/bench/benchmarks/string-pass/manifest.sh — sourced by run-bench.sh.

BENCH_ID=string-pass
BENCH_DESC="split/filter/upcase a 60 KB buffer into a growable output buffer"
BENCH_SUITE=m3
BENCH_ARG=400

BENCH_NOTE="One of M3's five. Counts toward the gate.

THE COUNTERWEIGHT TO tree-traversal, and it exists partly for that reason.

tree-traversal is uniform-size, burst-allocate, bulk-free: the best case for
ADR-0058's segregated size classes and close to the worst for malloc. DCDart
came out 2.3x FASTER there, which measured the allocator, not ARC.

GROWTH REALLOCATION INVERTS IT. C's realloc can frequently extend a block IN
PLACE when the following space is free -- no copy at all. DCDart's size classes
are fixed powers of two and a block never grows, so every doubling is
allocate-new-class + copy-everything + free-old, unconditionally. This is the
case DCDart's allocator handles WORST.

Neither benchmark is neutral. That is the point of having both, and it is why
reporting only the flattering one would be the exact failure ADR-0059 exists to
prevent.

IT ALSO MEASURES SOMETHING THAT WAS RECENTLY IMPOSSIBLE. Until ADR-0058's
Heap.allocate, DCDart could SLICE a string literal (Str, ADR-0053) and could
not produce one byte of new text at runtime. The buffer here is written the
way every DCDart program needing growable text must write it today, because
the prelude has no String or StrBuf type (GAP-0045) -- and that hand-written
buffer is itself part of what the gate is measuring.

INPUT IS GENERATED, NOT READ. Both sides run an identical recurrence, so
neither gets bytes for free from .rodata or from I/O, and the generation cost
falls on both equally.

CHECKSUM. Both sides return the same rolling hash of the OUTPUT bytes, so a
pass that dropped or mangled characters cannot produce a fast, wrong number."
