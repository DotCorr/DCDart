# DCDart

A native systems language with Dart's syntax and type system, compiled AOT to native code — no VM,
no interpreter, no JIT, no tracing GC. Memory is managed by ARC with compile-time elision and a local
cycle collector. C ABI at every boundary.

Everything buildable — compiler pipeline, runtime, examples, tests, and the full design-decision
record — lives under [`core/`](core/README.md). Start there.

## The three numbers that define the project

1. **ARC overhead vs. C.** Target ≤10% geometric mean. Gated at M3.
2. **Top-100 pub.dev packages passing their own test suites under DCDart.** Target ≥80% at M5.
3. **Undefined symbols in a `@bare` object file.** Target: zero, checked mechanically on every change.

## Status

M0 (Kernel IR seam) and M1 (type model) are done and verified end to end. M2 (ARC) has real
allocation/retain/release, aliasing, function calls, heap-typed signatures and fields, `@owned`
parameters, a destructor cascade, weak references, a first elision pass, verified recursion, scalar
local reassignment, and real `while`-loop control flow — all backed by a real `dcc build` →
freestanding link → run cycle, not stubs. See [`core/README.md`](core/README.md) for the current
target/ADR count and [`core/docs/known-gaps.md`](core/docs/known-gaps.md) for what's honestly still
missing.
