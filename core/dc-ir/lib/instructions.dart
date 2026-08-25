// core/dc-ir/instructions.dart
//
// The DC-IR instruction vocabulary. Started deliberately small (exactly
// what M0's `add(u64, u64) => a + b` needed), plus the ARC node shapes
// (Retain/Release) whose *shape* CLAUDE.md rule 4 wants frozen before M2
// starts writing an inserter against them. M1 added raw memory access
// (Load/Store/IntToPtr, spec §6 `Pointer<T>`) — see the section below.
//
// M1 also added ICmp (integer comparison, spec §5's `Result<T,E>`/`?`
// propagation needs a DCBool to branch on) — see the section below and
// docs/decisions/0013-icmp.md.
//
// SCOPE CUT — what is still NOT here, on purpose: struct field access
// (handled entirely in dcc-lower via existing instructions, see
// docs/decisions/0011), calls, allocation, `weak`/`unowned` reads, casts
// (`.toU32()`), bit ops (`& | ^ ~ << >> >>>`), `@volatile` semantics,
// pointer arithmetic (`.elementAt`), float comparisons. Add each when a
// real conformance target needs it, not speculatively; this file's
// existing shapes (dest/lhs/rhs typed via DCValue, sealed hierarchy,
// Overflow as its own enum rather than a bool) are the pattern to repeat.

import 'ssa.dart';
import 'types.dart';

/// Base of every DC-IR instruction. `result` is the `DCValue` the
/// instruction defines, or `null` for instructions with no value result
/// (`Retain`, `Release`, every `DCTerminator`).
///
/// Every non-terminator instruction defines at most one result — DC-IR has
/// no multi-result instructions. Nothing in the M0 instruction set needs
/// one; if a future instruction genuinely needs to define more than one
/// value (e.g. a combined div+rem), that's a new node shape to design then,
/// not a `List<DCValue> results` retrofitted onto this base class now.
sealed class DCInstruction {
  const DCInstruction();
  DCValue? get result;
}

// ---------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------

/// Materializes an integer literal into `dest`. `bits` is the raw bit
/// pattern; sign interpretation comes entirely from `dest.type` (a
/// `DCInt`) — DC-IR does not store a separately-signed literal value. This
/// mirrors how the backend will emit it: an LLVM `iN` constant has no sign
/// of its own either, only the operations performed on it do.
final class ConstInt extends DCInstruction {
  final DCValue dest; // dest.type must be a DCInt
  // Plain `int` (Dart's int is 64-bit on the native runtimes this tool
  // targets) — see ADR-0006. Conceptually a u64 raw bit pattern; a `dest`
  // typed narrower than 64 bits (e.g. DCInt.u8) still stores its value here
  // as a 64-bit host int, with only the low N bits meaningful. No masking
  // is performed at construction — that is dcc-lower's job when it builds
  // this node, not this type's.
  final int bits;
  const ConstInt({required this.dest, required this.bits});

  @override
  DCValue? get result => dest;
}

// ---------------------------------------------------------------------
// Arithmetic — spec §4.1
// ---------------------------------------------------------------------

/// Which overflow behavior an arithmetic instruction has. Spec §4.1: "traps
/// in both [debug and release] by default. Use explicit wrapping ops where
/// you mean it: `a &+ b` ... with a comment." That is a two-valued,
/// load-bearing distinction, so it is its own enum rather than a bare
/// `bool wrapping` field:
///   - `switch (overflow) { trapping => ..., wrapping => ... }` reads the
///     same as the source-level distinction it lowers from, at every call
///     site in dcc-lower and the backend.
///   - A future third behavior (saturating arithmetic, or a `Result`-
///     returning checked op) is a new enum case with an exhaustiveness
///     error at every switch that needs updating, not a second `bool`
///     nobody remembers to check.
enum Overflow { trapping, wrapping }

/// Integer add. `lhs`, `rhs`, and `dest` must all carry the same `DCInt`
/// type — DC-IR performs no implicit widening (spec §4.1: "no implicit
/// widening or narrowing"). A source-level `.toU32()` call lowers to an
/// explicit truncate/extend instruction; that instruction is not yet
/// defined here because M0's `add` never calls one — add it in M1 against
/// a real call site, not speculatively.
///
/// `a + b` in `core/examples/m0-seam/add.dart` lowers to one `IAdd` with
/// `overflow: Overflow.trapping` — plain `+` traps per spec §4.1, it is not
/// wrapping by default. See README.md "Worked example: M0's add.dart".
final class IAdd extends DCInstruction {
  final DCValue dest;
  final DCValue lhs;
  final DCValue rhs;
  final Overflow overflow;
  const IAdd({
    required this.dest,
    required this.lhs,
    required this.rhs,
    required this.overflow,
  });

  @override
  DCValue? get result => dest;
}

/// Integer subtract. Identical shape and overflow-mode contract to `IAdd`.
final class ISub extends DCInstruction {
  final DCValue dest;
  final DCValue lhs;
  final DCValue rhs;
  final Overflow overflow;
  const ISub({
    required this.dest,
    required this.lhs,
    required this.rhs,
    required this.overflow,
  });

  @override
  DCValue? get result => dest;
}

/// Integer multiply. Identical shape and overflow-mode contract to `IAdd`.
/// Included alongside `ISub` even though M0's `add` needs neither: `+`/
/// `-`/`*` are inseparable as a vocabulary (the first real conformance test
/// past `add` will need all three, per spec §4.1's `&+`/`&-`/`&*` trio),
/// and the shape is identical to `IAdd` — there is no meaningfully
/// different "come back and add this later" version of this instruction.
final class IMul extends DCInstruction {
  final DCValue dest;
  final DCValue lhs;
  final DCValue rhs;
  final Overflow overflow;
  const IMul({
    required this.dest,
    required this.lhs,
    required this.rhs,
    required this.overflow,
  });

  @override
  DCValue? get result => dest;
}

/// Integer division (`/`) and remainder (`%`).
///
/// NO `Overflow` field, and that is not an oversight: division does not
/// overflow the way `+`/`-`/`*` do, so there is no `llvm.*.with.overflow.*`
/// intrinsic for it and nothing for an `Overflow` flag to select. Division
/// has a DIFFERENT failure mode -- a zero divisor, which is undefined
/// behaviour in LLVM (`udiv i64 %a, 0` is `poison`, not a fault you can
/// rely on). The backend therefore emits an explicit compare-and-trap
/// against zero before the divide, so `x / u64(0)` halts deterministically
/// instead of silently producing poison. See ADR-0036.
///
/// Signedness comes from the operands' own `DCInt.signed`, selecting
/// `udiv`/`sdiv` (and `urem`/`srem`) in the backend -- the same mechanism
/// `IShr` already uses to pick `lshr` vs `ashr`, rather than splitting one
/// concept across two instruction classes.
final class IDiv extends DCInstruction {
  final DCValue dest;
  final DCValue lhs;
  final DCValue rhs;
  const IDiv({required this.dest, required this.lhs, required this.rhs});

  @override
  DCValue? get result => dest;
}

/// Integer remainder. See [IDiv] -- same zero-divisor trap, same
/// signedness rule (`urem`/`srem`).
final class IRem extends DCInstruction {
  final DCValue dest;
  final DCValue lhs;
  final DCValue rhs;
  const IRem({required this.dest, required this.lhs, required this.rhs});

  @override
  DCValue? get result => dest;
}

/// A pointer back to its integer address — the mirror of [IntToPtr]
/// (ADR-0055).
///
/// DCDart's whole pointer idiom is "an address in a `u64`, wrapped with
/// `Pointer<T>.fromAddress`". Until now the conversion only went one way, so
/// any pointer the compiler produced — a `Str`'s byte pointer, a struct field
/// holding one — was a dead end: you could dereference it, and you could not
/// do arithmetic on it. Walking a string one byte at a time needs exactly
/// that arithmetic.
final class PtrToInt extends DCInstruction {
  final DCValue dest;
  final DCValue pointer;
  const PtrToInt({required this.dest, required this.pointer});

  @override
  DCValue? get result => dest;
}

/// The null heap reference (ADR-0049).
///
/// A distinct instruction rather than a `ConstInt` with a pointer dest,
/// because `ConstInt` emits `add <type> N, 0` — valid for an integer, not for
/// a pointer. This emits LLVM's `null` constant directly.
///
/// `dest.type` is the `DCHeapPointer` of the nullable field or local being
/// initialized. `Retain`/`Release` are null-safe (ADR-0049), so a null may
/// flow through ARC without a guard at every use site.
final class NullRef extends DCInstruction {
  final DCValue dest;
  const NullRef({required this.dest});

  @override
  DCValue? get result => dest;
}

/// Explicit integer width conversion (`.toU8()`, `.toU16()`, `.toU32()`,
/// `.toU64()`), per DCDART_SPEC.md §4.1: "No implicit widening or
/// narrowing. `u8 -> u32` requires `.toU32()`. Explicit is the entire
/// point."
///
/// ONE instruction, not three (`zext`/`sext`/`trunc`), because the choice is
/// fully determined by the two types already present on `source` and `dest`:
/// a wider dest zero- or sign-extends depending on the SOURCE's signedness,
/// a narrower dest truncates, and equal widths are a no-op. Splitting it
/// would let a caller pass a combination that contradicts the types, which
/// is not a state worth being able to represent. Same reasoning as `IShr`
/// deriving `lshr` vs `ashr` from its operand rather than being two
/// instructions.
///
/// Narrowing TRUNCATES and does not trap. That is deliberate and matches
/// the spec: the explicit `.toU8()` call at the source level IS the safety
/// mechanism -- the programmer said the word "narrow", so the discarded high
/// bits are the stated intent, unlike an arithmetic overflow which is
/// always an accident.
final class IConvert extends DCInstruction {
  final DCValue dest;
  final DCValue source;
  const IConvert({required this.dest, required this.source});

  @override
  DCValue? get result => dest;
}

/// The address of a module-level global (ADR-0040), as an integer.
///
/// Names a SYMBOL, not a value. That is deliberate and follows the
/// precedent `Call.targetName` and `Alloc.destructorName` already set: DC-IR
/// has no cross-function value namespace (see ssa.dart), so a global cannot
/// be a `DCValue` that instructions in different functions both reference.
/// The name is resolved at emission.
///
/// `dest` is an integer, not a `DCPointer`, because the source-level surface
/// is `Rodata.addressOf(t) -> u64`, which composes with the existing
/// `Pointer<T>.fromAddress`. That keeps one way to make a pointer instead of
/// two.
final class AddressOfGlobal extends DCInstruction {
  final DCValue dest;
  final String globalName;
  const AddressOfGlobal({required this.dest, required this.globalName});

  @override
  DCValue? get result => dest;
}

/// Bitwise AND. `lhs`, `rhs`, `dest` must share the same `DCInt` type (no
/// implicit widening, same rule as arithmetic, spec §4.1). No `Overflow`
/// field -- bitwise ops don't have DCDart's arithmetic overflow-trap
/// semantics (spec §4.1's traps apply to `+`/`-`/`*`, not to bit
/// manipulation). Added for oscortex_core's interrupts milestone (IDT
/// entry field packing, PIC remap bit manipulation, UART status-register
/// polling -- see docs/known-gaps.md's former GAP-0006/GAP-0002 notes,
/// this closes the "no bitwise operators" half of both).
final class IAnd extends DCInstruction {
  final DCValue dest;
  final DCValue lhs;
  final DCValue rhs;
  const IAnd({required this.dest, required this.lhs, required this.rhs});

  @override
  DCValue? get result => dest;
}

/// Bitwise OR. Identical shape and contract to `IAnd`.
final class IOr extends DCInstruction {
  final DCValue dest;
  final DCValue lhs;
  final DCValue rhs;
  const IOr({required this.dest, required this.lhs, required this.rhs});

  @override
  DCValue? get result => dest;
}

/// Bitwise XOR. Identical shape and contract to `IAnd`.
final class IXor extends DCInstruction {
  final DCValue dest;
  final DCValue lhs;
  final DCValue rhs;
  const IXor({required this.dest, required this.lhs, required this.rhs});

  @override
  DCValue? get result => dest;
}

/// Left shift. `rhs` (the shift amount) must carry the same `DCInt` type
/// as `lhs`/`dest` -- DCDart has no implicit widening (spec §4.1), same
/// rule as every other binary op in this file, even though a narrower
/// shift-amount operand would be a reasonable thing to want later.
final class IShl extends DCInstruction {
  final DCValue dest;
  final DCValue lhs;
  final DCValue rhs;
  const IShl({required this.dest, required this.lhs, required this.rhs});

  @override
  DCValue? get result => dest;
}

/// Right shift. Logical (`lshr`) vs. arithmetic (`ashr`) is decided by
/// `lhs.type`'s signedness at the BACKEND (core/backend/lib/llvm_emit.dart),
/// not encoded as a separate instruction or predicate here -- unlike
/// `ICmp`'s ordering predicates (where `ult` vs `slt` are both
/// meaningful choices on either signedness), shift-right's behavior is
/// fully determined by the shifted value's own type, so a single
/// instruction reading the operand's signedness is simpler and cannot go
/// out of sync with it. Every current DCDart sized-int type (u8/u16/u32/
/// u64, see prelude.dart) is unsigned, so this always lowers to `lshr`
/// today -- the `ashr` path exists for when signed sized-int types get
/// real prelude support, which hasn't happened yet.
final class IShr extends DCInstruction {
  final DCValue dest;
  final DCValue lhs;
  final DCValue rhs;
  const IShr({required this.dest, required this.lhs, required this.rhs});

  @override
  DCValue? get result => dest;
}

/// Which comparison `ICmp` performs. Named after LLVM's own `icmp`
/// predicates (`eq`/`ne`/`ult`/`slt`/...) rather than inventing a DCDart-
/// specific set, since there is no DCDart-level distinction to invent here
/// beyond what LLVM already distinguishes -- signed vs. unsigned ordering
/// comparisons are meaningfully different operations (spec §4.1's sized
/// integers are explicitly signed OR unsigned, never ambiguous), so `lt`/
/// `le`/`gt`/`ge` are split by signedness the same way LLVM splits them;
/// `eq`/`ne` are not (equality doesn't care about sign).
enum ICmpPredicate { eq, ne, ult, ule, ugt, uge, slt, sle, sgt, sge }

/// Integer comparison, producing a `DCBool`. Added for spec §5's
/// `Result<T,E>`/`?` propagation, which needs *some* way to test "is this
/// Ok or Err" before CondBranch (instructions.dart, added M1) has anything
/// to branch on -- see docs/decisions/0013-icmp.md. `lhs`/`rhs` must carry
/// the same `DCInt` type (no implicit widening, same rule as arithmetic);
/// `dest.type` must be `DCBool`.
final class ICmp extends DCInstruction {
  final DCValue dest;
  final ICmpPredicate predicate;
  final DCValue lhs;
  final DCValue rhs;
  const ICmp({
    required this.dest,
    required this.predicate,
    required this.lhs,
    required this.rhs,
  });

  @override
  DCValue? get result => dest;
}

// ---------------------------------------------------------------------
// By-value aggregates — spec §5 (`Result<T,E>`). See
// docs/decisions/0014-result-value-representation.md and the "USED TWO
// WAYS" note on DCStruct in types.dart. NOT the pointer-backed struct
// pattern (spec §6, ADR-0011) -- these construct/take apart a struct-typed
// SSA value directly, nothing is ever read from or written to memory here.
// ---------------------------------------------------------------------

/// Constructs a `structType`-typed VALUE from `fields`, in the type's
/// declared field order. `dest.type` must equal `structType`;
/// `fields.length` must equal `structType.fields.length`, and each
/// `fields[i].type` must equal `structType.fields[i].type` exactly.
final class MakeStruct extends DCInstruction {
  final DCValue dest;
  final DCStruct structType;
  final List<DCValue> fields;
  const MakeStruct({
    required this.dest,
    required this.structType,
    required this.fields,
  });

  @override
  DCValue? get result => dest;
}

/// Extracts one field from a struct-typed VALUE (not a pointer -- compare
/// `Load`, which dereferences one). `struct.type` must be a `DCStruct`;
/// `fieldIndex` must be a valid index into its `fields`; `dest.type` must
/// equal `struct.type.fields[fieldIndex].type`.
final class ExtractField extends DCInstruction {
  final DCValue dest;
  final DCValue struct;
  final int fieldIndex;
  const ExtractField({
    required this.dest,
    required this.struct,
    required this.fieldIndex,
  });

  @override
  DCValue? get result => dest;
}

// ---------------------------------------------------------------------
// Raw memory — spec §6 (`Pointer<T>`). Added for M1's exit criterion
// ("a @bare program reads and writes a memory-mapped register through
// Pointer<u32>"), see docs/decisions/0010-pointer-load-store.md.
//
// NOT here yet, on purpose: `@volatile` semantics (spec §6 says the
// compiler must not reorder/elide volatile access -- these plain
// Load/Store carry no such guarantee; see docs/known-gaps.md), `.cast<U>()`,
// `.elementAt(n)` (pointer arithmetic), `Atomic<u32>`. Add when a real
// conformance target needs them, same discipline as the arithmetic
// instructions above.
// ---------------------------------------------------------------------

/// Loads a value through a raw pointer (spec §6 `Pointer<T>.value` getter).
/// `pointer.type` must be `DCPointer(T)` where `T == dest.type`.
final class Load extends DCInstruction {
  final DCValue dest;
  final DCValue pointer;

  /// Emit as `load volatile`, so the optimizer may not delete, duplicate,
  /// reorder or hoist it (DCDART_SPEC.md §6, ADR-0041).
  ///
  /// Defaults to FALSE, which is the safe default for the sites that
  /// dominate: heap-object field reads and the destructor cascade are
  /// ordinary memory, and making those volatile would cost ARC performance
  /// for no correctness benefit. Only `Pointer<T>.value` — the MMIO
  /// mechanism — sets it true.
  ///
  /// This is not a hypothetical. At `-O2` a non-volatile MMIO read-back is
  /// eliminated outright: `examples/m1-pointer/mmio.dart`'s store-then-read
  /// became "return what you wrote", and its conformance harness still
  /// passed, because the VALUE was right and only the hardware access was
  /// gone (known-gaps GAP-0006).
  final bool isVolatile;

  const Load({
    required this.dest,
    required this.pointer,
    this.isVolatile = false,
  });

  @override
  DCValue? get result => dest;
}

/// Stores a value through a raw pointer (spec §6 `Pointer<T>.value` setter).
/// `pointer.type` must be `DCPointer(T)` where `T == value.type`. No result
/// -- same "ops mutate through the pointer they're given" shape as
/// Retain/Release above, for the same reason.
final class Store extends DCInstruction {
  final DCValue pointer;
  final DCValue value;

  /// Emit as `store volatile`. See [Load.isVolatile] — same rule, same
  /// default, same reason.
  final bool isVolatile;

  const Store({
    required this.pointer,
    required this.value,
    this.isVolatile = false,
  });

  @override
  DCValue? get result => null;
}

/// Converts a raw integer address to a typed pointer (spec §6
/// `Pointer<T>.fromAddress`). `dest.type` must be `DCPointer(T)` for some T;
/// `address.type` must be an unsigned integer type (DCDart constructs
/// pointers from `usize`/`u64`, not signed integers -- there is no
/// well-defined "negative address").
final class IntToPtr extends DCInstruction {
  final DCValue dest;
  final DCValue address;
  const IntToPtr({required this.dest, required this.address});

  @override
  DCValue? get result => dest;
}

/// Computes `base + offsetBytes` as a raw pointer. Added for M2 heap-object
/// field access (docs/decisions/0016-heap-object-field-access.md):
/// `base.type` may be `DCPointer` OR `DCHeapPointer` — a heap object's
/// payload fields live at fixed byte offsets from its own address, the
/// same as a `@packed` struct's fields do from theirs (spec §6, ADR-0011),
/// just starting from an ARC'd base instead of a raw one. `dest.type` is
/// always a plain `DCPointer(T)` regardless of `base`'s type — a field
/// pointer computed this way is never itself independently retained/
/// released; only ARC's `Retain`/`Release` on the *whole object* (`base`,
/// if it's a `DCHeapPointer`) manage its lifetime. Not used for `@packed`
/// struct field access (that predates this instruction and already works
/// via `ConstInt`+`IAdd`+`IntToPtr` on a raw `u64` address, ADR-0011) —
/// kept as-is rather than refactored, since it already works and isn't
/// broken.
final class PtrOffset extends DCInstruction {
  final DCValue dest;
  final DCValue base;
  final int offsetBytes;
  const PtrOffset({required this.dest, required this.base, required this.offsetBytes});

  @override
  DCValue? get result => dest;
}

/// Writes a byte to an x86 I/O port (the `outb` instruction) — oscortex_core's
/// M0 escalation, docs/decisions/0029-port-io.md. `port.type` must be
/// `DCInt.u16` (x86's port address space is 16 bits), `value.type` must be
/// `DCInt.u8`. **Privileged (ring-0-only)**: executing this in a normal
/// Linux userspace process traps (SIGSEGV) — unlike every other instruction
/// in this file, this one cannot be verified by running compiled code on the
/// dev host, only by inspecting the emitted codegen shape (structurally) or
/// by actually running as kernel code under full-system emulation (QEMU).
/// Byte-width only (`outb`) — word/dword port I/O (`outw`/`outl`) not added,
/// nothing needs them yet, same "build exactly what's needed" discipline as
/// everywhere else in this file.
final class PortOut extends DCInstruction {
  final DCValue port;
  final DCValue value;
  const PortOut({required this.port, required this.value});

  @override
  DCValue? get result => null;
}

/// Reads a byte from an x86 I/O port (the `inb` instruction). `dest.type`
/// must be `DCInt.u8`, `port.type` must be `DCInt.u16`. Same
/// privileged-instruction verification caveat as `PortOut` above.
final class PortIn extends DCInstruction {
  final DCValue dest;
  final DCValue port;
  const PortIn({required this.dest, required this.port});

  @override
  DCValue? get result => dest;
}

// ---------------------------------------------------------------------
// Atomics and barriers — spec §6's required-primitives table
// (docs/decisions/0055-atomics.md, 0056-memory-barriers.md).
//
// Two mechanisms, two ADRs, and they are kept apart here on purpose.
// ATOMICITY is a property of ONE access (it cannot be interleaved).
// ORDERING is a property of the relationship BETWEEN accesses. Neither
// implies the other, and a node that carried both would invite code that
// asks for one and silently gets the other's guarantee.
// ---------------------------------------------------------------------

/// Which read-modify-write an [AtomicRmw] performs. Names match LLVM's own
/// `atomicrmw` opcodes exactly (`add`/`sub`/`and`/`or`/`xor`/`xchg`), so the
/// backend needs no translation table — the same choice ADR-0013 made for
/// `ICmpPredicate`.
///
/// Deliberately absent: `nand`, `max`/`min`/`umax`/`umin`. LLVM has them and
/// x86 lowers them to a `cmpxchg` loop; nothing needs them, and each is a
/// one-line addition here plus one in the emitter when something does.
enum AtomicOp { add, sub, and, or, xor, xchg }

/// An indivisible read (`load atomic ... seq_cst`). `pointer.type` must be
/// `DCPointer(T)` where `T == dest.type`, and `T` must be a `DCInt` of 1, 2,
/// 4 or 8 bytes.
///
/// Distinct from `Load(isVolatile: true)`, and the distinction is not
/// cosmetic. Volatile stops the OPTIMIZER deleting or duplicating an access;
/// it says nothing about whether the hardware performs it as one indivisible
/// operation, and on a misaligned or oversized location it will not. Atomic
/// is the machine-level guarantee. Nothing in this project may substitute one
/// for the other.
///
/// No ordering field: every atomic here is sequentially consistent
/// (ADR-0055). Weaker orderings are a widening, addable later without
/// invalidating any program compiled today; a weak default could never have
/// been tightened.
final class AtomicLoad extends DCInstruction {
  final DCValue dest;
  final DCValue pointer;
  const AtomicLoad({required this.dest, required this.pointer});

  @override
  DCValue? get result => dest;
}

/// An indivisible write (`store atomic ... seq_cst`). Same type rule as
/// [AtomicLoad]. No result, same shape as `Store`.
final class AtomicStore extends DCInstruction {
  final DCValue pointer;
  final DCValue value;
  const AtomicStore({required this.pointer, required this.value});

  @override
  DCValue? get result => null;
}

/// An indivisible read-modify-write (`atomicrmw <op> ... seq_cst`).
/// `dest` receives the contents as they were BEFORE the operation, matching
/// C11, LLVM and x86 `xadd`.
///
/// This is the node GAP-0039 is about. `p.value = p.value + 1` on a `@bss`
/// counter is three separable steps; this is one.
///
/// **Arithmetic here WRAPS, and cannot do otherwise.** Every other integer
/// operation in this file carries an [Overflow] and traps by default (spec
/// §4.1). An atomic RMW has no such option: the overflow is only observable
/// after the write has already been committed, and there is nothing to roll
/// back to. Recorded as an explicit field-free fact rather than an `Overflow`
/// field that would only ever hold one value.
final class AtomicRmw extends DCInstruction {
  final DCValue dest;
  final DCValue pointer;
  final AtomicOp op;
  final DCValue value;
  const AtomicRmw({
    required this.dest,
    required this.pointer,
    required this.op,
    required this.value,
  });

  @override
  DCValue? get result => dest;
}

/// Which ordering a [Fence] establishes. Names match LLVM's `fence` orderings
/// (`acquire`/`release`/`acq_rel`/`seq_cst`), plus one that is not an LLVM
/// ordering at all.
///
/// [compilerOnly] is the odd one out and is spelled out because a reader will
/// otherwise assume it is `monotonic`/relaxed. LLVM has no "compiler-only
/// fence" ordering — `fence monotonic` is not even legal IR. The mechanism is
/// an empty `asm sideeffect` with a `~{memory}` clobber, which is exactly what
/// Linux's `barrier()` is. It emits no instruction on any target and
/// constrains only the compiler.
enum DCOrdering { acquire, release, acqRel, seqCst, compilerOnly }

/// A memory barrier. No operands, no result — it constrains the movement of
/// other instructions and computes nothing.
///
/// Not foldable, not removable, not duplicable by any pass. `dc-elide`'s
/// dead-value analysis works on `result`, and this instruction has none, so
/// it is never a candidate for removal — but that is a property of how that
/// pass happens to be written, so anything added later that removes
/// result-less instructions must exclude this one explicitly.
final class Fence extends DCInstruction {
  final DCOrdering ordering;
  const Fence({required this.ordering});

  @override
  DCValue? get result => null;
}

/// Allocates a heap object (spec §3.1's `DCObject` header + payload) and
/// returns a pointer to its payload (the header sits at a fixed negative
/// offset — see docs/decisions/0015-m2-minimal-arc-arena.md). `dest.type`
/// must be `DCHeapPointer`; `payloadSizeBytes` is the payload's byte size
/// only (the header's own size is a backend/runtime constant, not
/// DC-IR's concern). Initializes strong=1, weak=0, cls=`destructorName`'s
/// address (or null — see below).
///
/// M2's first slice (ADR-0015): backed by a fixed internal arena, NOT the
/// real `Allocator` (that's spec §12's open decision 2, escalated
/// separately — see docs/escalations/0002-allocator-threading.md). This
/// instruction's *shape* (allocate, get a DCHeapPointer back) is expected
/// to hold once the real Allocator lands; only the backend's *lowering* of
/// it will change.
///
/// `destructorName` (docs/decisions/0022-destructor-cascade.md, M2's sixth
/// ARC slice): the link name of a function to call (via the header's `cls`
/// field, spec §3.1) when `Release` (below) brings this object's strong
/// count to zero — `null` for a class with no heap-typed fields, meaning
/// nothing needs releasing when this object dies (the vast majority of
/// classes so far). **This is a direct destructor call, NOT a real
/// `ClassInfo` vtable** — DCDart has no dynamic dispatch yet (spec §4.3's
/// monomorphization is M5+ scope), so every heap object's concrete class is
/// always statically known at its own `Alloc` site; `cls` is populated with
/// exactly one function's address, never chosen among several at runtime.
/// A real vtable (multiple virtual slots, chosen by runtime type) is
/// GAP-0003's remaining, still-deferred scope, not implemented here.
final class Alloc extends DCInstruction {
  final DCValue dest;
  final int payloadSizeBytes;
  final String? destructorName;
  const Alloc({required this.dest, required this.payloadSizeBytes, this.destructorName});

  @override
  DCValue? get result => dest;
}

/// Calls another function by its link name (`DCFunction.linkName`),
/// passing `args` positionally. `dest` is `null` iff the callee's return
/// type is `DCVoid`; otherwise its type must equal the callee's declared
/// return type exactly (same "no implicit widening" rule as every other
/// instruction here). Added for GAP-0018 (docs/known-gaps.md): every
/// conformance target through M2's second slice was a single leaf
/// function — there was no way to call one `@bare` function from another
/// at all.
///
/// Direct, non-virtual call only: DCDart has no dynamic dispatch story
/// yet (spec §4.3's monomorphization is out of scope until M5+), so
/// `targetName` names exactly one function in the same module — no
/// vtable/`ClassInfo` lookup is involved, unlike a real method call would
/// eventually need.
///
/// Ownership convention for heap-typed args (docs/decisions/0017's
/// aliasing reasoning extends here): a `DCHeapPointer`-typed argument is
/// passed BORROWED — the caller does not `Retain` before the call and the
/// callee must not track its own heap-typed parameters in its naive
/// release list. Not yet exercised by any conformance target — `dcc-lower`
/// does not lower `DCHeapPointer`-typed parameters at all yet (GAP-0017),
/// this convention is recorded now so it's decided once, not per call
/// site later.
final class Call extends DCInstruction {
  final DCValue? dest;
  final String targetName;
  final List<DCValue> args;

  /// Parallel to `args` (same length) -- `true` at position *i* when that
  /// argument is passed to an `@owned` parameter (spec §3.2 item 2: the
  /// callee fully consumes it), `false` when borrowed. Added for the first
  /// slice of move semantics (spec §3.2 pass 4, docs/decisions/0031-move-
  /// semantics.md): without this, an elision pass has no DC-IR-level way
  /// to tell "the callee borrows, so a Retain/Release pair spanning this
  /// call is load-bearing" apart from "the callee fully consumes, so the
  /// pair is redundant" -- both look identical as a plain opaque `Call`
  /// (see docs/decisions/0025-redundant-pair-removal.md's own worked
  /// example of exactly this ambiguity). `dcc-lower` already computes this
  /// exact fact per argument today (it decides whether to emit a caller-
  /// side `Retain` from it) -- this just also records it here instead of
  /// discarding it.
  final List<bool> argOwnership;

  const Call({
    this.dest,
    required this.targetName,
    required this.args,
    required this.argOwnership,
  });

  @override
  DCValue? get result => dest;
}

// ---------------------------------------------------------------------
// ARC — spec §3.1. Shape frozen in spirit by CLAUDE.md rule 4 ("memory-
// model changes are frozen after M3") even though M2 (elision) and M3 (the
// ARC gate) have not happened yet — see README.md "Why Retain/Release
// exist in an M0 deliverable".
// ---------------------------------------------------------------------

/// Increments the strong refcount of a heap object (spec §3.1's
/// `dc_retain`, inlined). No `result` — ARC ops mutate the object in place
/// through the pointer they are given; they do not produce a new SSA value
/// the way an arithmetic op does. `object.type` must be a `DCHeapPointer`
/// (types.dart) — passing a raw `DCPointer` here is a dcc-lower bug, not a
/// legal "no-op retain on an unmanaged pointer". The type distinction
/// exists precisely so that mistake cannot compile silently.
final class Retain extends DCInstruction {
  final DCValue object;
  const Retain({required this.object});

  @override
  DCValue? get result => null;
}

/// Decrements the strong refcount of a heap object; runs the destructor and
/// frees at zero (spec §3.1's `dc_release`, inlined). Same operand-typing
/// contract as `Retain`; no `result`.
///
/// Deliberately NOT encoded here, still: *which* destructor runs. As
/// originally planned, that's resolved entirely through the object header's
/// `cls` field (spec §3.1) when `Release` is lowered to LLVM IR in
/// `backend/` (docs/decisions/0022-destructor-cascade.md) — `Alloc`
/// (above) is what decides `cls`'s value, once, at construction; `Release`
/// itself stays exactly this simple regardless of how many classes exist
/// or how deep a cascade goes, since dcc-lower never needs to know a
/// release site's class to emit this instruction correctly.
final class Release extends DCInstruction {
  final DCValue object;
  const Release({required this.object});

  @override
  DCValue? get result => null;
}

// ---------------------------------------------------------------------
// weak — spec §3.3 layer 1 (docs/decisions/0023-weak-references.md, M2's
// eighth ARC slice). `object`/`weak`.type must be `DCHeapPointer`/
// `DCWeakPointer` respectively (types.dart) — same type-safety reasoning
// as Retain/Release's operand contract above.
// ---------------------------------------------------------------------

/// Constructs a weak reference from a strong one: increments the target's
/// `weak` header count (spec §3.1) WITHOUT touching `strong` — a
/// `DCWeakPointer` never keeps its target alive. `dest`'s numeric value
/// equals `object`'s (same payload address, different DCType tag);
/// `dest.type` must be `DCWeakPointer(T)` for some `T`, `object.type` must
/// be `DCHeapPointer`.
final class MakeWeak extends DCInstruction {
  final DCValue dest;
  final DCValue object;
  const MakeWeak({required this.dest, required this.object});

  @override
  DCValue? get result => dest;
}

/// Reads a weak reference's target — spec §3.3's "nils out when the
/// target dies." Checks the target's `strong` header count: zero means
/// dead, and `dest` is the null pointer, no retain performed; nonzero
/// means alive, and this instruction ALSO retains (increments `strong`)
/// before returning the live address — `dest` is therefore a genuine
/// fresh-owned `DCHeapPointer` (or null), the same "you now own this
/// reference, release it like any other" contract every other
/// fresh-ownership source in this project already has
/// (docs/decisions/0017's `_isFreshHeapOwnership`, extended to recognize
/// this shape too). Retaining is done HERE, inside this one instruction,
/// rather than leaving it to whichever call site captures the result —
/// deciding "alive or dead" and "retain if alive" together in one place
/// avoids ever retaining a null pointer, which would corrupt memory (see
/// the ADR). `dest.type` must be `DCHeapPointer`, `weak.type` must be
/// `DCWeakPointer`.
final class WeakLoad extends DCInstruction {
  final DCValue dest;
  final DCValue weak;
  const WeakLoad({required this.dest, required this.weak});

  @override
  DCValue? get result => dest;
}

/// Drops a weak reference: decrements the target's `weak` header count.
/// If BOTH `weak` and `strong` are now zero, the arena slot is finally
/// freed here — a target whose `strong` hit zero while `weak` was still
/// nonzero is NOT freed by `Release` (docs/decisions/0022's destructor
/// cascade already ran at that point; only the memory reclaim is
/// deferred) precisely so a still-alive `DCWeakPointer` can keep
/// correctly observing "dead" (`WeakLoad` above) until nothing — strong
/// OR weak — references the slot any longer. No `result`, same shape as
/// `Release`. `object.type` must be `DCWeakPointer`.
final class DropWeak extends DCInstruction {
  final DCValue object;
  const DropWeak({required this.object});

  @override
  DCValue? get result => null;
}

// ---------------------------------------------------------------------
// Terminators — exactly one ends every basic block (see function.dart
// `DCBasicBlock`'s invariant note).
// ---------------------------------------------------------------------

/// A `DCInstruction` that ends a basic block. Every `DCBasicBlock.body`
/// must end in exactly one of these and contain none elsewhere.
sealed class DCTerminator extends DCInstruction {
  const DCTerminator();
}

/// Ends the function, optionally producing a value. `value` is `null` iff
/// the enclosing `DCFunction.returnType` is `DCVoid`; otherwise
/// `value.type` must equal the function's declared return type exactly (no
/// implicit widening, same rule as arithmetic).
///
/// `add.dart`'s `return a + b` (implicit, via `=>`) lowers to
/// `Return(value: <the IAdd's dest>)`.
final class Return extends DCTerminator {
  final DCValue? value;
  const Return({this.value});

  @override
  DCValue? get result => null;
}

/// Unconditional jump to `target`, binding `args` positionally to
/// `target`'s block parameters. `args.length` must equal the target
/// block's `params.length`, and each arg's type must equal the
/// corresponding param's type. This — not a separate phi instruction — is
/// how DC-IR represents merge points; see ssa.dart's header note and
/// README.md "Why block-parameter SSA, not phi nodes".
final class Branch extends DCTerminator {
  final BlockId target;
  final List<DCValue> args;
  const Branch({required this.target, required this.args});

  @override
  DCValue? get result => null;
}

/// Two-way branch. `cond.type` must be `DCBool` (not a bare integer — see
/// `DCBool`'s note in types.dart for why that distinction is enforced at
/// the type level rather than by convention). Each side has its own
/// argument-binding rule, identical to `Branch`'s, and the two targets are
/// allowed to have entirely different parameter lists.
final class CondBranch extends DCTerminator {
  final DCValue cond;
  final BlockId trueTarget;
  final List<DCValue> trueArgs;
  final BlockId falseTarget;
  final List<DCValue> falseArgs;
  const CondBranch({
    required this.cond,
    required this.trueTarget,
    required this.trueArgs,
    required this.falseTarget,
    required this.falseArgs,
  });

  @override
  DCValue? get result => null;
}
