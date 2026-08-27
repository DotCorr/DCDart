// Repro for the void-function scope-release leak, found by NEON N1's
// tensor library (2026-08-27).
//
// THE BUG: `_lowerReturn` releases every tracked heap/weak local (and
// `@owned` parameter) on an EXPLICIT `return`, but a void function whose
// body falls off the end takes a different path — the implicit
// `Return()` synthesized at the end of `_lowerBody` — and that path
// emitted NO releases at all. Every heap local and every `@owned`
// parameter in such a function leaked. Invisible to the whole existing
// suite because no prior target had a void `@bare` function that tracked
// anything: `@owned` consumers all RETURNED values (m2-owned's
// `dropBoxAndReadValue`), and void functions all took borrowed params
// (m2-rawheap's `sbDestroy`). NEON's `tensorRelease(@owned Tensor t) {}`
// — a consuming release whose empty body IS the operation — is the
// smallest possible function that hits it.
//
// Three shapes below, each a real N1 call site reduced to a Box:
// consuming with an empty body, a fresh local falling off the end, and an
// alias local + if/else where both branches fall through.
import '../../runtime/dc-core-bare/prelude.dart';

class Box extends HeapObject {
  u64 v;
  Box(this.v);
}

/// The empty-body consumer (NEON's tensorRelease): the `@owned` release IS
/// the function. Before the fix: release count 0, every box leaked.
@bare
void dropBox(@owned Box b) {}

/// A fresh heap LOCAL falling off the end of a void function — no
/// `@owned` involved, so this proves the leak was about the implicit
/// return path, not about the ownership annotation.
@bare
void makeAndForget(u64 v) {
  final b = Box(v);
}

/// The tensorDestroyViaBase shape: a VOID function with an alias local
/// (alias retain, ADR-0017) plus an if/else whose branches BOTH fall
/// through to the implicit return. Two tracked references (`b` owned,
/// `c` alias) must both be released at the fall-off-the-end point after
/// the merge — the scalar `tag` reassignment keeps the merge block real.
@bare
void inspectAndDrop(@owned Box b, u64 threshold) {
  final c = b;
  var tag = u64(0);
  if (threshold < c.v) {
    tag = u64(1);
  } else {
    tag = u64(2);
  }
}

/// Driver: churns `n` boxes through all three shapes. The C harness
/// asserts dc_heap_live == 0 after this returns — before the fix it was
/// 3n (dropBox's param, makeAndForget's local, and inspectAndDrop's
/// param, per iteration).
@bare
u64 churn(u64 n) {
  var i = u64(0);
  while (i < n) {
    dropBox(Box(i));
    makeAndForget(i);
    inspectAndDrop(Box(i), u64(10));
    i = i + u64(1);
  }
  return i;
}
