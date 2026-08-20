// core/dc-ir/function.dart
//
// The container structure: basic blocks, functions, and modules. This is
// the shape `dcc-lower` builds and `backend/` consumes.

import 'instructions.dart';
import 'ssa.dart';
import 'types.dart';

/// One basic block: an id, its SSA parameters, and a straight-line body
/// ending in exactly one terminator.
///
/// `params` are the values other blocks' `Branch`/`CondBranch` (see
/// instructions.dart) bind their `args` into when jumping here — this is
/// DC-IR's only merge-point mechanism (no phi instruction; see
/// README.md "Why block-parameter SSA, not phi nodes").
///
/// INVARIANT (not enforced by this type — see README "What isn't validated
/// by construction"): every element of `body` except the last must NOT be
/// a `DCTerminator`, and the last MUST be one. A verifier pass over
/// `DCFunction` — not yet written, belongs with whoever writes the first
/// real `dcc-lower` — is where this gets checked mechanically.
final class DCBasicBlock {
  final BlockId id;
  final List<DCValue> params;
  final List<DCInstruction> body;
  const DCBasicBlock({
    required this.id,
    required this.params,
    required this.body,
  });
}

/// Compilation mode, spec §2. Threaded onto `DCFunction` (not left implicit
/// from "whichever file it came from") because the backend's lowering
/// genuinely diverges on it — no ORC calls, no allocator-implicit paths, no
/// exceptions-shim — and because `scripts/verify-freestanding.sh`
/// (CLAUDE.md rule 1) only makes sense to run against something that
/// claims to be `bare`.
enum DCMode { bare, hosted }

/// One function: a fixed signature, a mode, and its basic blocks.
///
/// `blocks[0]` is always the entry block, and the function's formal
/// parameters ARE `blocks[0].params` — there is no separate parameter
/// list distinct from block parameters. This is one mechanism doing both
/// jobs on purpose: a function's parameters are exactly "the SSA values
/// live at entry", which is precisely what a block's `params` represents
/// for every other block already. `paramTypes` is kept alongside as the
/// function's externally-visible signature (what `backend/` needs to
/// generate a C-ABI-compatible symbol per spec §9, before it has looked at
/// any block) — it must equal `blocks[0].params.map((v) => v.type)`
/// exactly; this redundancy is deliberate; see README "What isn't
/// validated by construction".
///
/// WORKED EXAMPLE. `core/examples/m0-seam/add.dart`'s
/// `@bare u64 add(u64 a, u64 b) => a + b;` lowers to:
///
/// ```dart
/// DCFunction(
///   linkName: 'add',
///   paramTypes: [DCInt.u64, DCInt.u64],
///   returnType: DCInt.u64,
///   mode: DCMode.bare,
///   blocks: [
///     DCBasicBlock(
///       id: BlockId(0),
///       params: [
///         DCValue(ValueId(0), DCInt.u64), // a
///         DCValue(ValueId(1), DCInt.u64), // b
///       ],
///       body: [
///         IAdd(
///           dest: DCValue(ValueId(2), DCInt.u64),
///           lhs: DCValue(ValueId(0), DCInt.u64),
///           rhs: DCValue(ValueId(1), DCInt.u64),
///           overflow: Overflow.trapping, // plain `+` traps, spec §4.1
///         ),
///         Return(value: DCValue(ValueId(2), DCInt.u64)),
///       ],
///     ),
///   ],
/// )
/// ```
///
/// Zero `Retain`/`Release` anywhere in this function — `u64` is a value
/// type (spec §3.1's `DCObject` header is a heap-object concept; nothing
/// here is heap-allocated), so ARC insertion in dcc-lower has nothing to
/// do for `add`. That is the expected M0 output, not a gap: the ARC node
/// shapes (instructions.dart `Retain`/`Release`) exist so M2's inserter has
/// something correct to target later, not because M0 needs to emit them.
final class DCFunction {
  final String linkName; // e.g. "add" from @linkName, or the mangled name
  final List<DCType> paramTypes;
  final DCType returnType;
  final DCMode mode;
  final List<DCBasicBlock> blocks;

  const DCFunction({
    required this.linkName,
    required this.paramTypes,
    required this.returnType,
    required this.mode,
    required this.blocks,
  });
}

/// One EXTERNAL C-ABI symbol this module calls but does not define
/// (DCDART_SPEC.md §9, docs/decisions/0038-extern-symbols-and-linking.md).
///
/// A signature and nothing else — there are no blocks, because the body is
/// in somebody else's object file. This is deliberately NOT a `DCFunction`
/// with an empty block list: "a function with no blocks" is an invalid
/// `DCFunction` by its own invariant (`blocks[0]` is always the entry
/// block), and every pass that walks `module.functions` would have to learn
/// to skip it. A separate list means those passes are correct by
/// construction — `dc-elide`, `dc-objdump --arc` and the destructor
/// synthesis all keep seeing exactly the set of functions that have bodies.
///
/// WHY THERE IS NO `CallExtern` INSTRUCTION. At the call site there is
/// nothing to distinguish: a call to an external C-ABI symbol and a call to
/// a sibling `@bare` function emit the identical machine instruction, take
/// arguments the same way, and are subject to the same optimizer rules.
/// What actually differs is purely module-level — whether the symbol gets a
/// `define` or a `declare` — so that is where the distinction lives. See
/// the ADR's "Options" section.
final class DCExternFunction {
  /// The C symbol name, emitted verbatim. No mangling, ever (spec §9).
  final String linkName;
  final List<DCType> paramTypes;
  final DCType returnType;

  const DCExternFunction({
    required this.linkName,
    required this.paramTypes,
    required this.returnType,
  });
}

/// The initializer of a [DCGlobal], as a TREE rather than a byte blob.
///
/// This shape is deliberate and is the one part of ADR-0040 built for a
/// capability nothing can reach yet. A flat `List<int>` of bytes would be
/// simpler and would serve every case the language can express today — and
/// it would have to be thrown away the moment a global needs to hold the
/// ADDRESS of another global, because an address is not a value the compiler
/// knows: it is a hole the linker fills. Modelling initializers as a tree
/// with a relocation leaf ([DCConstAddrOf]) from the start makes that an
/// extension rather than a redesign.
sealed class DCConstant {
  const DCConstant();
}

/// A scalar integer, emitted at the width of its [type].
final class DCConstInt extends DCConstant {
  final DCInt type;
  final int value;
  const DCConstInt(this.type, this.value);
}

/// A fixed-length array of same-typed elements, emitted as `[N x T]`.
///
/// No length word and no header of any kind: the emitted aggregate is
/// exactly the elements, so the global's address IS element 0's address.
/// Consumers read these through a raw `Pointer<T>`, where a prefix would
/// silently shift every index rather than fail — which is why
/// `tests/conformance/rodata/` asserts the emitted bytes instead of trusting
/// this comment.
final class DCConstArray extends DCConstant {
  final DCType elementType;
  final List<DCConstant> elements;
  const DCConstArray(this.elementType, this.elements);
}

/// The ADDRESS of another global, plus a byte offset — a relocation.
///
/// UNREACHABLE FROM SOURCE TODAY, and present on purpose. `@rodata` requires
/// a `final` field with a `const` initializer, and a `const` initializer
/// cannot reference a `final` field, so no `@rodata` table can name another
/// one. Reaching this leaf needs an all-`const` surface, which trades away
/// the declaration identity `final` buys. ADR-0040 calls that fork its
/// central finding; this node exists so resolving it later is a lowering
/// change rather than an IR redesign.
///
/// Because nothing reaches it, nothing exercises it — so `dc-ir`'s own test
/// suite builds this shape directly and asserts what it emits. An
/// unreachable node with no test rots silently and is discovered broken by
/// whoever first needs it.
final class DCConstAddrOf extends DCConstant {
  final String globalName;
  final int offsetBytes;
  const DCConstAddrOf(this.globalName, {this.offsetBytes = 0});
}

/// One module-level constant, emitted into read-only data.
///
/// There is deliberately NO `isMutable` field. A mutable module-level static
/// is a global variable, which is a memory-model question — `CLAUDE.md`
/// rule 4, frozen after M3, escalate rather than decide. A field existing
/// only to be rejected would pre-commit the shape of an escalation nobody
/// has held, so it is absent rather than present-and-refused.
final class DCGlobal {
  /// The emitted symbol name, verbatim (spec §9).
  final String linkName;
  final DCConstant initializer;

  /// Emitted as an explicit `align N`. Explicit rather than left to LLVM:
  /// nothing else in DCDart emits alignment for anything, so a consumer
  /// reading this through a raw pointer has no other way to know what it
  /// got.
  final int alignBytes;

  const DCGlobal({
    required this.linkName,
    required this.initializer,
    required this.alignBytes,
  });
}

/// A compilation unit — what `dcc-lower` hands to `backend/` as one job,
/// and roughly what becomes one object file. M0 only ever has one function
/// in one module (`add`); `DCModule` exists as a thin wrapper now so that
/// "one function per module" isn't accidentally load-bearing anywhere
/// downstream.
final class DCModule {
  final String name;
  final List<DCFunction> functions;

  /// External C-ABI symbols this module calls but does not define
  /// (ADR-0038). Defaults to empty, so every module built before extern
  /// declarations existed constructs exactly as it did.
  ///
  /// This list is the ONLY authority on which undefined symbols the emitted
  /// object file is allowed to carry — `dcc` writes it out as a manifest
  /// beside the object and `scripts/verify-freestanding.sh` checks `nm -u`
  /// against it (CLAUDE.md rule 1). Anything undefined that is not in here
  /// is still a hard failure.
  final List<DCExternFunction> externFunctions;

  /// Module-level read-only constants (ADR-0040). Defaults to empty, so
  /// every module built before static data existed constructs unchanged.
  ///
  /// A separate list from `functions`, for the same reason `externFunctions`
  /// is one: every pass that walks `module.functions` — `dc-elide`,
  /// `dc-objdump --arc`, destructor synthesis — keeps seeing exactly the set
  /// of things that have bodies, and needs no change to stay correct.
  final List<DCGlobal> globals;

  const DCModule({
    required this.name,
    required this.functions,
    this.externFunctions = const [],
    this.globals = const [],
  });
}
