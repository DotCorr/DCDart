# ADR-0058: A real heap — segregated size classes, and the allocator question split in two

**Status:** decided under delegated authority — implemented and verified

**Escalation status, stated first.** This touches spec §12 open decision 2 (`Allocator` threading),
which `CLAUDE.md` lists as escalate-only, and it changes allocation behaviour, which is the memory
model under rule 4. `docs/escalations/0002-allocator-threading.md` was opened for it and explicitly
deferred the call: *"a real evaluation should look at what M2's actual call patterns turn out to need
once more of the ARC insertion logic exists, not be made speculatively now."* **M2 now exists, so
that evaluation is possible**, and the owner delegated the remaining M3 decisions. Decided here,
with the reversal path recorded, rather than deferred again.

## Context — the arena was not a small heap, it was not a heap

ADR-0015 shipped a `[64 x [64 x i8]]` static array with a LIFO free list of slot indices, correctly
labelled at the time as a first proof of ARC codegen rather than an allocator. It was never revisited.
Measured, not inferred:

| limit | value | failure mode |
|---|---|---|
| live objects | **64** | `deep(64)` = 2080; `deep(65)` traps |
| payload size | **48 bytes** (64 − 16 header) | compile-time refusal |
| allocation site | **not inside a loop body** | compile-time refusal (lowering, separate) |

All three failed loudly, which is why they produced no wrong answers and also why nobody noticed the
aggregate. **Together they made every one of M3's five benchmarks unwritable** — including the
tree/graph traversal, which needs no `String`, no generics and no closures and had therefore been
listed in a status report as the one that *was* writable. It was not: a tree with more than 64 live
nodes does not fit. GAP-0050.

There is a second reason this blocks M3 that is easy to miss. **The gate's number is ARC overhead vs
C, and C's baseline is `malloc`/`free`.** A fixed-slot LIFO over a static array has no size classes,
no coalescing and no fragmentation; allocation is a pop and free is two stores. Measuring against it
would have produced a *flattering* number describing a program nobody can write. The allocator is not
a prerequisite of the benchmarks — it is part of what the benchmarks measure.

## The finding that decides §12.2: it is two questions, not one

The spec frames the allocator question as one choice — explicit parameter (Zig) vs implicit context
(Odin). Having M2 makes it clear these are **two different allocation populations with different
answers**, and that the Zig framing does not transfer cleanly because *Zig has no ARC*:

1. **ARC object creation is compiler-emitted.** `Node(i)` in source becomes an `Alloc` instruction.
   There is no call site to thread an allocator through — an explicit parameter would mean rewriting
   every constructor signature in the language and having the compiler thread a value into
   instructions it inserts on the user's behalf. Zig never faces this because Zig never inserts an
   allocation the programmer did not write.
2. **Library data structures are ordinary calls.** `StrBuf`, a growable list, an arena for a request
   — these are hand-written functions where an explicit `Allocator` parameter is natural, honest
   about cost, and exactly what `CLAUDE.md`'s coding rule already requires.

**Decision: explicit at the region, implicit at the ARC allocation site.** Library allocation keeps
the explicit-parameter model (option 1, as escalation 0002 recommended). ARC allocation draws from a
per-module heap that the backend emits, because there is no user-authored call site to thread
anything through.

This is *not* the "hidden global heap" `CLAUDE.md` forbids for `@bare`: the heap is a named `.bss`
symbol (`dc_heap`) of a size fixed at build time and visible in the object file, not an ambient
thread-local reachable from anywhere. What is deliberately **not** decided here is the source-level
spelling that makes the region's declaration explicit (a `@heap final myHeap = Heap(bytes: …)`), which
is the honest end state for a kernel that wants its heap where it says. See *Reversal path*.

## Decision — segregated size classes

The heap is `_heapClassCount` equal-sized regions, one per size class
(32, 64, 128, 256, 512, 1024, 2048, 4096 bytes, block including header), each with a bump cursor and
an intrusive free-list head. All zero-initialized, so all of it lands in `.bss`.

**A block's size class is a function of its ADDRESS** — `(addr − heapBase) / regionBytes` — and that
single choice is what everything else falls out of:

- **The 16-byte object header is unchanged.** A conventional allocator stores the size class in a
  header word. Doing that here would have meant editing spec §3.1, which is the memory model and rule
  4 — a far larger decision than this one, taken as a side effect of an implementation convenience.
  Deriving the class from the address costs **one shift** on the free path and touches no spec text.
- **`Alloc` does no class arithmetic at all.** `Alloc.payloadSizeBytes` is a compile-time constant, so
  the class index and block size are resolved during emission. Allocation is a free-list pop, or a
  bump and bounds check.
- **Free lists are intrusive** — a free block holds its successor in its own first 8 bytes, over the
  dead strong/weak counts. Safe precisely because the block is unreachable. This is why the smallest
  class is 32 bytes and not 16: a free block must have room for a pointer.

### Size classes are derived from the region, not fixed

Powers of two from 32 bytes up to whichever is smaller: 1 MiB, or the region itself. A *fixed* list
forces one of two bad outcomes — sized for a hosted benchmark it makes every freestanding region
carry classes it can never satisfy, and sized for a kernel it caps a hosted string builder at a few
kilobytes. 32 is the floor because a free block stores its successor in its own first 8 bytes on top
of the 16-byte header.

### Results, measured

| | before | after (hosted, 2 MiB region) | after (freestanding, 64 KiB) |
|---|---|---|---|
| live objects, smallest class | 64 | **65,536** | 2,048 |
| payload bytes per object | 48 | **1,048,560** | 65,520 |
| total `.bss` | 4 KiB | 32 MiB | **768 KiB** |

The payload figure is the one that changes what can be written: **48 bytes to 1 MiB is a factor of
about 21,000**, and it is the difference between a language that can hold a parsed document and one
that cannot.

`oscortex_core` measured its own side rather than taking the default on faith: its `.bss` is ~70 KiB
today and it maps one `PT_LOAD` with 2 MiB pages, so a 768 KiB heap still fits inside a single page
mapping. A hosted-sized default would have needed eight of them — a silent structural change to a
downstream boot path, arriving as an allocator default.

Verified end to end rather than asserted: `deep(5000)` returns 12,502,500 (= 5000·5001/2, checked
independently); **200 × `deep(5000)` — one million allocations through a 2 MiB region — returns the
correct value**, which is the free-list reuse proof, since without reuse it would exhaust the region
at 65,536; and the OOM boundary is exactly where the arithmetic says, 65,536 succeeding and 65,537
trapping. That last one matters more than it looks: an off-by-one in the bump check is the difference
between a clean trap and writing one block past the region into the next size class's storage.

### Two refusals that are checked, not assumed

`emitModule` rejects a region size that is **not a power of two**, because the class-from-address
division is emitted as a shift and a non-power-of-two would compute the wrong class, pushing a freed
block onto the wrong free list — a later `Alloc` of one size then hands back a block of another.
That is **silent heap corruption, not a crash**, which is the one failure mode this design can have,
so it is refused at the only place it can be introduced. It also rejects a region smaller than the
largest size class, which could never satisfy a single allocation of that class.

## Runtime-sized allocation, and why it is the same decision

`Alloc` allocates an ARC object whose size is a compile-time constant. That is not enough for
anything that owns growable storage, so this ADR also adds `AllocRaw`/`FreeRaw` and their source
surface, `Heap.allocate(n)` / `Heap.free(p)`.

**This is the explicit half of §12.2 made real.** ARC allocation is implicit because there is no
call site to thread anything through; raw allocation is named at every use, returns un-managed bytes
with no header and no destructor, and the caller frees it exactly once. `Heap.allocate` is `malloc`
with `malloc`'s hazards — double-free is undetected and produces a cycle in a free list — which is
precisely why it is spelled out rather than made ambient.

**Freeing takes no size**, because the class comes from the address. In a conventional allocator
`free(ptr)` needs a header word to know the block's size; here it does not, and that is the same
property that let spec §3.1's object header stay untouched. One design choice paying twice.

The class computation is the one runtime arithmetic on the path: classes are consecutive powers of
two from 32, so the index is `64 - ctlz(n - 1) - 5`. Worked through in the emitter's comment rather
than left to the reader, because an off-by-one hands back a block one class too small and the
resulting overflow is **silent**.

**What it unblocks, demonstrated rather than claimed.** `tests/conformance/rawheap/` builds a
`StrBuf` from a capacity of **one** byte to 500,000, reallocating at nearly every power of two —
about nineteen times, each one allocating at a runtime size, copying, and freeing the old block. Every
byte is verified and `dc_heap_live` is asserted back at zero after every call. Until this existed,
DCDart could *slice* a string literal (`Str`, ADR-0053) and could not produce **one byte of new text
at runtime**, which is what M3's string-processing pass and JSON parser both require.

Two things that fell out and are worth naming:

- **`Pointer<T>.address` did not exist.** `Pointer.fromAddress` has been there since M1, so a pointer
  could be made from an address but never turned back into one. Indexing a raw buffer needs
  `fromAddress(p.address + i)`. Added; `elementAt` (spec §6, GAP-0051) remains the right ergonomic
  answer, since every caller of `.address` restates the element stride by hand.
- **`Heap.free` is refused in an arrow body.** It is void-returning and recognized in statement
  position only, so `=> Heap.free(x)` fails while `{ Heap.free(x); }` works. `Atomic.store` and
  `Port.outb` share this exactly. It is a real wart and it is the kind that reads as a compiler bug
  to whoever hits it first.

## What this does NOT do

**It does not make M3's benchmarks writable on its own.** Closures, generic classes and owning
`String` are still missing, and a heap-typed local still cannot be declared inside a loop body — that
last one is a lowering question (per-iteration release policy), not an allocator one, and is being
fixed separately. This removes the ceiling; it does not fill the room.

**There is no `free` for non-ARC memory, and no `Allocator` type yet.** Nothing user-written can ask
this heap for bytes. `StrBuf` and every other library data structure still need the explicit-parameter
API this ADR chose but did not build.

**No coalescing, no splitting, no return to the OS.** A block freed in one size class never becomes
available to another. A program that allocates a million 32-byte objects, frees them all, then wants
one 4096-byte object draws from a region that has never been touched — fine — but a program whose
size mix shifts over its lifetime will hold peak-usage memory for every class simultaneously. For a
benchmark suite and a kernel this is acceptable and predictable; for a long-running server with a
varying workload it is not. **This is the single most likely thing to make an M3 number look better
than a real allocator would**, and it must be stated next to whatever number M3 produces.

**It is not thread-safe.** The bump cursors and free-list heads are plain loads and stores with no
atomics. That is consistent with `docs/escalations/0007-arc-refcount-atomicity.md`'s finding that ARC
refcounts are non-atomic and unreachable-by-construction today, and it inherits exactly the same
deadline: whatever answers 0007 must answer this at the same time, because a heap with atomic
refcounts and non-atomic free lists is not a coherent design.

## Consequences

- **Reversal path.** The externally visible commitments are the `dc_heap`/`dc_heap_bump`/
  `dc_heap_free` symbol names, the size-class list, and the region size. All three are backend
  emission details with no source-level surface, so all three are reversible while nothing links
  against them by name — `oscortex_core` links a DCDart object and must be re-checked before this is
  called stable. The *un*reversible commitment is the one deliberately avoided: the 16-byte header is
  unchanged, so no program's object layout moved.
- **A requirement on whoever adds the `Allocator` type:** it must be able to express *this* heap as
  one implementation among several, not be retrofitted around it. If the first `Allocator` interface
  is shaped by what the backend happens to emit, the explicit-parameter decision above becomes
  decorative.
- **The conformance suite's green state carried no information about allocation at scale**, and still
  carries little. Every existing target that allocates was sized to fit under 64 — most visibly
  `m2-recursion` at depths 0–60. Those tests were correct and honestly written; they simply could not
  have failed differently if the allocator had been far worse. A target that allocates at scale is
  part of this unit for that reason.
- ADR-0015 is superseded for the arena, and its *reasoning* is worth keeping: it said plainly that
  the arena was a first proof and not the real allocator, and it named the escalation. It was not
  wrong; it was left in place too long, which is a project-management failure rather than a technical
  one, and the lesson is that a deliberately temporary mechanism needs an owner and a trigger, not
  just an honest label.
