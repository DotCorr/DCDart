# ADR-0063: elision pass 3 must not cancel a pair across a surviving `Release`

**Status:** decided. Closes `docs/known-gaps.md` GAP-0054. Fixes a **live miscompilation** —
a use-after-free emitted by the shipping compiler at `-O2`.

**Not a rule-4 change.** ARC conventions, `weak`/`unowned` semantics, the ORC trigger policy, the
object header and release *placement* are all untouched. `dcc-lower` emits exactly the same DC-IR as
before; only which pairs `dc-elide` is willing to delete changes. What this ADR *does* surface is a
rule-4 question it deliberately does not answer — see "The cost" and escalation 0011.

## Context

ADR-0025's pass 3 deletes `retain(x) … release(x)` when no release **of `x`** appears between them.
It reasons over **DCValues**. A DCValue is not an object, and two DCValues routinely denote the same
runtime object — that is the entire premise of ADR-0017's alias retain, where `%b = Load %a.field`
produces a second value for an object `%a.field` already holds.

So "no release of `x` in between" is not the statement the safety argument needs, which is "nothing
in between can free this object".

GAP-0054 recorded this in the abstract and, correctly, did not claim it was reachable: in
`boxNode` the elided pair does straddle a release of an aliasing value, and it is safe, because
`got.n` is lowered *before* `_releaseHeapLocals` emits anything. There is no use after the premature
free because there is no use at all.

**That is a property of how `dcc-lower` orders a return — a different file, asserted nowhere.**

### It was reachable

`examples/m3-elide-alias/elide_alias.dart` puts a use after the release, using only shapes the
language already had (ADR-0048's heap-field store, which emits a `Release` of the old value
*mid-function*):

```dart
var n = Node(v);          // alloc                                  -> rc 1
final c = Cell(n);        // field store                            -> rc 2
n = Node(u64(0));         // ADR-0048 releases the old local        -> rc 1  (field is sole owner)
final got = c.next;       // ADR-0017 alias retain                  -> rc 2
c.next = Node(u64(1));    // ADR-0048 releases the old field value  -> rc 1
final other = Node(u64(198));
return got.n;             // read
```

Pass 3 saw `Retain got … Release got` with no release *of `got`* between them and deleted both. With
the pair gone the count reads `1 -> 0` at the field store: **the object is freed while `got` still
points at it.** `Node(u64(198))` then takes the freed slot off the free list and writes 198 over the
payload.

Through `dcc build` at `-O2`, on `main` at `e76d6ec`:

```
aliasBug(110) = 198        <- correct answer is 110
dc_heap_live  = 0          <- correct
```

**And that is why this survived.** Cancelling a pair is refcount-**neutral**: the object is freed
exactly once, just far too early. `dc_heap_live` returns to zero, every refcount balances, there is
no double free to trap on. **No leak test in this repo could see it**, and the leak test is the check
M2 and M3 lean on hardest.

## Decision

**A `Release` that SURVIVES this pass invalidates every pending retain, not only a matching one.** A
`Release` the pass *deletes* as half of a cancelled pair invalidates nothing, because it never
executes.

Two lines of code. The whole content is in which releases count.

### Why this is sufficient, stated as an invariant

Cut a block at every **surviving** `Release`. Inside one of the resulting gaps the transformed
program contains **no decrement of anything at all** — deleted releases do not execute, and every
remaining decrement is a gap boundary by construction.

Both members of an elided pair now lie inside a single gap (a pair spanning a boundary is
invalidated). Therefore:

- the original and transformed refcounts **agree at every gap boundary** — all pairs opened inside a
  gap are closed inside it, so nothing is outstanding across a boundary;
- within a gap the transformed count only ever **rises** from that boundary value;
- the boundary value is ≥ 1, because the original program was correct and the object is live there.

So the count can never reach zero inside an elided pair's interval. ∎

Note what the argument does **not** mention: where `_releaseHeapLocals` runs, or whether the last use
precedes the releases. **The invariant is local to the pass**, which is precisely what GAP-0054 said
was missing.

This also completes the pass's own safety story, which is now sayable in one sentence: the only three
ways a refcount can go down are an executed `Release`, an opaque callee, and a weak op — and all
three clear.

### Rejected: narrow it with an alias analysis

A pending retain on a value defined by `Alloc` in this block that has not since escaped cannot be the
object another value releases, so it could be spared.

**Tried, measured, rejected.** It recovers `m2-loopheap`'s `lastKept` and **neither of the other two**
— both of those retain a value that came from a `Load` or a `Call`, where nothing local establishes
identity. It buys back **none** of the measured cost, in exchange for a second aliasing argument
living in the pass where a wrong aliasing argument is a double free. That is the trade that created
GAP-0054 in the first place.

It is written up in GAP-0066 as the thing to reach for if a future workload shows a loss it *would*
recover.

### Rejected: disable pass 3

Not considered seriously, and recorded only because it is the tempting shape of this fix. It would
have "passed" every correctness test in the suite while costing elision on every benchmark. The
conformance target asserts `stillElided` has **retain=0** specifically so that this failure mode is
caught rather than celebrated.

## The cost — and it is not zero

Per-target, `bench/elision-delta.sh` (retains lowered → retains surviving), `main` at `e76d6ec` vs
this change. **Aggregate percentages are deliberately not quoted**: they are dominated by tiny
straight-line programs and move on their own as the target mix changes.

| target | before | after | pairs lost |
|---|---|---|---|
| `json` | 19 → 18 | 19 → 19 | **1** |
| `m2-loopheap` | 2 → 1 | 2 → 2 | **1** |
| `m3-generic-class` | 2 → 1 | 2 → 2 | **1** |
| `m3-elide-alias` | 7 → 1 | 7 → 3 | 2 *(this ADR's own reproducer)* |
| `tree-traversal` | 6 → 4 | 6 → 4 | 0 |
| `m2-list` | 12 → 9 | 12 → 9 | 0 |
| `m2-closure` | 4 → 0 | 4 → 0 | 0 |
| `m2-owned` | 1 → 0 | 1 → 0 | 0 |
| `m2-heap-field` | 1 → 0 | 1 → 0 | 0 |
| `m2-alias` | 2 → 0 | 2 → 0 | 0 |
| `m3-funcptr` | 6 → 1 | 6 → 1 | 0 |
| `string-pass`, `arc-churn` | 0 → 0 | 0 → 0 | 0 |

**Exactly three pre-existing pairs stop being elided, and each is attributed:**

- **`json`'s `parseArray`** — `tail = child` retains `child` across the release of the previous
  `tail`. Both are values this pass cannot tell apart; one is a `Call` result, the other a `Load`.
- **`m2-loopheap`'s `lastKept`** — `keep = node` retains across the reassignment's release of the
  previous `keep`.
- **`m3-generic-class`'s `boxNode`** — the pair straddles `Release b`, and `Box$Node_dtor` releases
  `b.value`, the very object the retain protects. **This is the case GAP-0054 was found in.**

The three 100% targets (`m2-closure`, `m2-owned`, `m2-heap-field`, and `m2-alias`) are **unchanged**,
which is the evidence that pass 3 has not been turned into a no-op: they are straight-line with no
aliasing release, and every pair in them still cancels.

### Runtime

`json` is the only benchmark whose object file changes. Two interleaved A/B runs, 600 samples a side,
same driver, alternating processes to remove batch drift:

```
run 1:   24.626 ms -> 25.728 ms    +4.5%
run 2:   40.805 ms -> 42.511 ms    +4.2%
```

(The absolute times differ because the machine was under very different load; the *relative* delta
reproduces.) `tree-traversal`, `string-pass` and `arc-churn` produce **byte-identical binaries**, so
their timing deltas across the same runs are a noise floor, measured at ±2%.

**So: a measured ~4% regression on one M3 benchmark, in exchange for removing a use-after-free.**

This is worth stating plainly because it contradicts the expectation this work started from, which
was that the surrendered elision would measure as zero. It does not. It is still the right trade —
a wrong answer is not a performance characteristic — but it is a trade, and the number belongs next
to the decision rather than in a footnote.

**What would recover it** is knowing that `parseValue`'s *result* is a freshly-allocated `+1`
distinct from everything live. DCDart's ARC conventions carry ownership on *parameters* (`@owned`,
ADR-0021) and, since ADR-0060, in a function pointer's type — but nothing says anything about a
**return value's uniqueness**. That is a spec §3 question under rule 4, so it is escalation 0011 and
GAP-0066, not something invented here.

## Verification

- **Negative control, both ways.** `examples/m3-elide-alias`, built by `dcc build` at `-O2`:
  `aliasBug(110)` returns **198 before** the fix and **110 after**. The pre-fix binary demonstrably
  fails, so the control is not vacuous.
- **`tests/conformance/elide-alias/`** — freestanding, exact ARC counts in **both** directions
  (pairs that must survive *and* `stillElided`, which must still read `retain=0`), and behaviour.
  It fails on the pre-fix pass.
- **`dc-elide` unit tests** — 15, up from 11. The two new negative ones fail against the pre-fix
  pass; the two new positive ones pass against both, which is what makes them a no-op guard.
- **Conformance suite: 41/41** on Darwin/arm64, hosted link mode.
- **Benchmark checksums unchanged** — `json` 911486030, `tree-traversal` 683814029, `string-pass`
  121686398, `arc-churn` 5995601978946, each agreeing across DCDart, C and trap-matched C.

## Consequences

- Pass 3's safety no longer depends on anything outside `dc-elide/lib/elide.dart`. `dcc-lower` is
  free to move release placement (GAP-0050's per-iteration policy, GAP-0060's fall-off-the-end exit
  releases) without silently re-arming this bug.
- Elision on linked structures is now bounded by two separate things: this aliasing rule, and the
  intra-block limit that GAP-0062 measured. **They are independent.** The null-test extension is a
  separate unit; mixing an elide-less change with an elide-more one makes a regression in either
  direction unattributable when one of them is a use-after-free.
- `bench/elision-delta.sh`'s recorded baseline is now stale for `json`, `m2-loopheap` and
  `m3-generic-class`. GAP-0066 carries the new numbers.
