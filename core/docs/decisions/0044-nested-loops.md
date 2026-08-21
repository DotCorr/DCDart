# ADR-0044: Nested `while` loops

**Status:** decided — implemented and verified (`tests/conformance/nested/`)

## Context

ADR-0028 built `while` and explicitly refused to nest:

```dart
if (stmt is WhileStatement) {
  throw DccLowerError('"$context": nested while-loops are not supported yet');
}
```

The stated reason was that recursing would "silently scope the carried-variable analysis to the wrong
loop". Nothing tested nesting, so the refusal sat unexamined until `oscortex_core` hit it **twice in
one milestone**, in two unrelated subsystems (PCI bus enumeration and a framebuffer console), by an
agent that was not looking for it. It was being routed around by hand in kernel code — the shape of
workaround that becomes load-bearing if it sits.

## Decision

Recurse into the nested loop's body. One line.

**The refusal was over-cautious: the safeguard it wanted already existed one level up.**
`_lowerWhile` keeps only candidates already present in `_values` — i.e. variables declared *before*
this loop began:

```dart
final loopVars = [for (final v in candidates) if (_values.containsKey(v)) v];
```

So the two cases separate themselves without any "declared inside vs outside" AST analysis:

- A variable declared **inside** the inner body is not in `_values` when the outer header is built, so
  it is excluded automatically. It is fresh each iteration and genuinely not carried.
- A variable declared **outside** and assigned by the inner loop **is** in `_values`, so it is
  collected — which is correct, because that assignment does escape to the next outer iteration.

The second case is precisely what ADR-0028's comment feared getting wrong, and it is the one the
existing filter handles correctly. Recursing was always safe; nothing had checked.

## Verification

Three cases, chosen for what they would break rather than for coverage:

- **`innerWritesOuter`** — an inner loop assigning a variable declared outside the outer loop. The
  exact mis-scoping worry. `innerWritesOuter(4,3) == 3 × (0+1+2+3)`.
- **`triple`** — three levels, so nothing depends on there being exactly two. `triple(4) == 64`.
- **`findPair`** — an `if`/`else` inside the inner loop with an early `return` out of **both**,
  exercising the phi-predecessor tracking ADR-0028 had to fix a real backend bug for in the
  single-loop case.

All freestanding-clean, all run natively, every value hand-checked.

## Consequences

- Two M3 prerequisites' worth of programs become writable: `ROADMAP.md`'s JSON parser and tree
  traversal both need nested loops. This does not close GAP-0035 — six prerequisites remain — but it
  removes an obstacle that was on the path regardless of how the mutable-statics decision goes.
- `oscortex_core` can drop its hand-written workarounds.
- **The lesson is about the shape of the refusal, not the loop.** A deliberate, well-commented "not
  supported yet" that names a real-sounding hazard reads as considered, and is therefore *less* likely
  to be re-examined than a crash would be. This one was wrong for eleven ADRs and was found by a
  downstream consumer, not by the suite. Every other "not supported yet" in `dcc-lower` deserves the
  same five minutes: the check may already exist elsewhere.
- Still unsupported inside a loop body, and still deliberately: `break`/`continue` (no
  `BreakStatement` lowering), and heap- or weak-typed locals declared in the body (no ARC policy for
  the back edge — the same undecided question as escalation 0006).
