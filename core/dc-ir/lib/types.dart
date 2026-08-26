// core/dc-ir/types.dart
//
// DC-IR's value-type vocabulary (DCDART_SPEC.md §1: "DC-IR — typed SSA,
// explicit retain/release"). Every DCValue in the IR (see ssa.dart) carries
// exactly one DCType.
//
// SCOPE NOTE — read before extending this file. This is the M0 type
// vocabulary plus the minimum needed to type Retain/Release. It is
// deliberately NOT the full DCDart surface type system from spec §4:
//   - No generics. Spec §4.2 monomorphizes generics away in dcc-lower,
//     upstream of DC-IR ever seeing a type. A `List<u32>` and a `List<u8>`
//     arrive here as two unrelated concrete DCStructs, not one generic node.
//   - No vtables/interfaces. Classes lower to DCStruct plus a separate,
//     not-yet-designed ClassInfo (vtable + destructor + layout descriptor,
//     spec §3.1). See docs/known-gaps.md GAP-0003. That's M1/M2 work.
//   - No `Str`/`String`/`StrBuf`. Spec §7 types are stdlib types built ON
//     TOP OF DCPointer + DCInt (a `Str` is a two-field struct: ptr, len).
//     They are not new DCType variants.
// Extending this file for M1/M2 features (structs with more shapes, the
// eventual heap-object layout) is expected. Extending it to reintroduce
// generics, reflection, or `dynamic` would be re-deciding spec §4.4, which
// is closed — don't.
//
// EQUALITY. `==`/`hashCode` on every DCType below are structural
// (value-based), not identity-based, on purpose: dcc-lower asks "are these
// two DCTypes the same type" constantly — block-parameter/branch-argument
// type checking (instructions.dart), constant folding, ARC's escape
// analysis grouping values by type (M2). Two DCType instances built
// independently but describing the same type must compare equal, the same
// way two `int`s that happen to both be `5` compare equal.

/// Base of every DC-IR value type. Sealed so a `switch` over `DCType` in
/// dcc-lower or the backend is exhaustiveness-checked by the (upstream
/// Dart) compiler building *this* compiler — the one guardrail available
/// before DCDart's own exhaustive-switch checking exists to police itself.
sealed class DCType {
  const DCType();
}

/// Sized integers, spec §4.1. Widths and signedness are the only two axes;
/// `int`/`i64` is represented as `DCInt(IntWidth.w64, signed: true)` — by
/// the time Kernel IR reaches dcc-lower, `int` has already been resolved to
/// `i64` per spec §4.1's aliasing rule ("`int` is an alias for `i64`").
/// There is no separate "bare `int`" DCType.
final class DCInt extends DCType {
  final IntWidth width;
  final bool signed;
  const DCInt(this.width, {required this.signed});

  static const DCInt u8 = DCInt(IntWidth.w8, signed: false);
  static const DCInt u16 = DCInt(IntWidth.w16, signed: false);
  static const DCInt u32 = DCInt(IntWidth.w32, signed: false);
  static const DCInt u64 = DCInt(IntWidth.w64, signed: false);
  static const DCInt usize = DCInt(IntWidth.wSize, signed: false);
  static const DCInt i8 = DCInt(IntWidth.w8, signed: true);
  static const DCInt i16 = DCInt(IntWidth.w16, signed: true);
  static const DCInt i32 = DCInt(IntWidth.w32, signed: true);
  static const DCInt i64 = DCInt(IntWidth.w64, signed: true);
  static const DCInt isize = DCInt(IntWidth.wSize, signed: true);

  @override
  bool operator ==(Object other) =>
      other is DCInt && other.width == width && other.signed == signed;

  @override
  int get hashCode => Object.hash(DCInt, width, signed);

  // Diagnostics only. dcc-lower's type-mismatch errors interpolate a DCType
  // directly ("passes argument 0 of type $actual for a parameter declared
  // $expected"), and Dart's default `Instance of 'DCInt'` makes those messages
  // useless exactly when someone needs them. Added with `DCFuncPtr`
  // (ADR-0060), whose own `toString` nests these.
  @override
  String toString() {
    final w = switch (width) {
      IntWidth.w8 => '8',
      IntWidth.w16 => '16',
      IntWidth.w32 => '32',
      IntWidth.w64 => '64',
      IntWidth.wSize => 'size',
    };
    return '${signed ? 'i' : 'u'}$w';
  }
}

/// `isize`/`usize` are a distinct width, not sugar for `w64`: DC-IR must
/// stay honest about target pointer width for a future 32-bit target
/// (spec §9 mentions SysV AMD64 / AAPCS64 as the initial two, not the only
/// two). Resolving `wSize` to a concrete bit width is a backend concern
/// (DC-IR → LLVM IR), not a DC-IR type-identity concern — two `usize`
/// values are the same DCType regardless of which target they'll compile
/// for.
enum IntWidth { w8, w16, w32, w64, wSize }

/// Floats, spec §4.1 (`f32 f64`). Split out from `DCInt` rather than an
/// `isFloat` flag on one integer-shaped node: float arithmetic has no
/// overflow-trap semantics (see instructions.dart `Overflow`) and no
/// wrapping-op family, so folding it into `DCInt` would mean every
/// consumer has to remember which fields are meaningless for floats.
final class DCFloat extends DCType {
  final FloatWidth width;
  const DCFloat(this.width);

  static const DCFloat f32 = DCFloat(FloatWidth.w32);
  static const DCFloat f64 = DCFloat(FloatWidth.w64);

  @override
  bool operator ==(Object other) => other is DCFloat && other.width == width;

  @override
  int get hashCode => Object.hash(DCFloat, width);

  @override
  String toString() => width == FloatWidth.w32 ? 'f32' : 'f64';
}

enum FloatWidth { w32, w64 }

/// Not `DCInt(IntWidth.w8, signed: false)` wearing a trenchcoat. Spec §4.1
/// lists bit ops "on all integer types" and says nothing about `bool`;
/// `true & false` is boolean logic, not integer arithmetic, and a
/// `CondBranch` condition (instructions.dart) is typed `DCBool` specifically
/// so nothing ever lets an arbitrary integer flow into a branch condition
/// without an explicit comparison producing a real `DCBool` first.
final class DCBool extends DCType {
  const DCBool();

  @override
  bool operator ==(Object other) => other is DCBool;

  @override
  int get hashCode => (DCBool).hashCode;

  @override
  String toString() => 'bool';
}

/// The empty type. Never a `DCValue.type` — nothing produces a value of
/// type `DCVoid` — legal only as `DCFunction.returnType` for a function
/// that returns nothing.
final class DCVoid extends DCType {
  const DCVoid();

  @override
  bool operator ==(Object other) => other is DCVoid;

  @override
  int get hashCode => (DCVoid).hashCode;

  @override
  String toString() => 'void';
}

/// Spec §6: `Pointer<T>`. `pointee` is itself a `DCType`, so pointer-to-
/// pointer, pointer-to-struct, etc. all fall out of this one node instead
/// of needing a separate IR type per level of indirection.
///
/// This is a *raw*, non-refcounted pointer — the FFI/MMIO kind from spec
/// §6, not a reference to a DCObject. Opaque/untyped pointers (C's `void*`)
/// are `DCPointer(DCVoid())` rather than a separate node.
///
/// See `DCHeapPointer` below for the ARC'd counterpart — the two are
/// deliberately different DCTypes so `Retain`/`Release` (instructions.dart)
/// can reject a raw `DCPointer` operand at construction time instead of
/// silently no-op'ing on a pointer nothing is refcounting.
final class DCPointer extends DCType {
  final DCType pointee;
  const DCPointer(this.pointee);

  @override
  bool operator ==(Object other) => other is DCPointer && other.pointee == pointee;

  @override
  int get hashCode => Object.hash(DCPointer, pointee);

  @override
  String toString() => 'Pointer<$pointee>';
}

/// Marks "this is what ARC operates on" — conceptually a pointer to a heap
/// allocation carrying the `DCObject` header from spec §3.1
/// (`strong`/`weak`/`cls`). `pointee` is the payload type living after that
/// header.
///
/// What is deliberately NOT decided here, and tracked as
/// docs/known-gaps.md GAP-0003: the concrete layout of `ClassInfo`
/// (vtable + destructor + layout descriptor), and whether `weak`/`unowned`
/// (spec §3.3) end up as distinct DCTypes or as a flag on `DCHeapPointer`.
/// Both are M1/M2 (vtables, ARC insertion) decisions. M0's `add(u64, u64)`
/// never constructs a `DCHeapPointer` — this type exists purely so
/// `Retain`/`Release` (instructions.dart) have a real operand type to
/// check against now, per CLAUDE.md rule 4 ("memory-model changes are
/// frozen after M3" — the node shape should be right before M2 writers
/// start coding against it, not bolted on after).
final class DCHeapPointer extends DCType {
  final DCType pointee;
  const DCHeapPointer(this.pointee);

  @override
  bool operator ==(Object other) => other is DCHeapPointer && other.pointee == pointee;

  @override
  int get hashCode => Object.hash(DCHeapPointer, pointee);

  @override
  String toString() => 'HeapRef<$pointee>';
}

/// Spec §3.3 layer 1: `weak`. Does NOT keep its target alive (no strong
/// refcount contribution) — the object's `weak` header field
/// (`DCObject.weak`, spec §3.1) tracks how many `DCWeakPointer`s exist
/// instead. A weak pointer's own numeric address is identical to the
/// `DCHeapPointer` it was made from (both name the same payload); the
/// distinct `DCType` exists so `MakeWeak`/`WeakLoad`/`DropWeak`
/// (instructions.dart) can be typed distinctly from `Retain`/`Release`'s
/// strong-only operand, the same reasoning `DCHeapPointer` itself already
/// uses to keep raw and ARC'd pointers from being confused
/// (docs/decisions/0023-weak-references.md).
///
/// `unowned` (spec §3.3, a non-nilling variant that traps on
/// use-after-free instead of returning null) is NOT this type and is not
/// implemented yet — see `docs/known-gaps.md`.
final class DCWeakPointer extends DCType {
  final DCType pointee;
  const DCWeakPointer(this.pointee);

  @override
  bool operator ==(Object other) => other is DCWeakPointer && other.pointee == pointee;

  @override
  int get hashCode => Object.hash(DCWeakPointer, pointee);

  @override
  String toString() => 'Weak<$pointee>';
}

/// One field of a `DCStruct`. `name` is carried for diagnostics and debug
/// info only — it is NOT part of struct identity (see `DCStruct.==` below).
final class DCStructField {
  final String name;
  final DCType type;
  const DCStructField(this.name, this.type);
}

/// A fixed, non-generic, C-layout-compatible struct (spec §6, `extends
/// Struct`). `fields` is in declaration/storage order; DC-IR does not
/// reorder fields for packing — `@packed`/`@align` (spec §6) are resolved
/// to concrete offsets by dcc-lower before a `DCStruct` is built, upstream
/// of this type existing.
///
/// No generic structs reach this type: by the time a Kernel IR `Struct`
/// subtype arrives at dcc-lower it has already been monomorphized (spec
/// §4.2) into one `DCStruct` per concrete instantiation.
///
/// Two `DCStruct`s are equal iff their field *types*, in order, are equal —
/// `name` and field `name`s are excluded from equality on purpose. DC-IR's
/// notion of "same type" is "same layout", the same way LLVM's structural
/// (non-identified) struct types work; two independently-built structs with
/// identical layout but different source names must unify, or every
/// monomorphized instantiation of the same generic would look like a
/// different type to the backend.
///
/// USED TWO WAYS, both legitimate, neither baked into this type itself:
/// (1) a *pointer-backed* layout descriptor (spec §6 `@packed`/`Struct`) —
/// ADR-0011's implementation actually never constructs a `DCStruct` value
/// for this case, it represents struct instances as raw addresses and
/// reaches fields via `IntToPtr`+`Load`/`Store`, so this use is really just
/// documentation of *why* a given address's bytes are laid out a certain
/// way; (2) a genuine *by-value* small aggregate (spec §5 `Result<T,E>`,
/// docs/decisions/0014-result-value-representation.md) — constructed and
/// taken apart via `MakeStruct`/`ExtractField` below, never spilled to
/// memory at the DC-IR level. Whether a given `DCStruct` is "by pointer" or
/// "by value" is determined by which instructions a consumer uses on it,
/// not by anything recorded on the type.
final class DCStruct extends DCType {
  final String name;
  final List<DCStructField> fields;
  const DCStruct(this.name, this.fields);

  @override
  bool operator ==(Object other) {
    if (other is! DCStruct) return false;
    if (other.fields.length != fields.length) return false;
    for (var i = 0; i < fields.length; i = i + 1) {
      if (other.fields[i].type != fields[i].type) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(fields.map((f) => f.type));

  @override
  String toString() => 'struct $name{${fields.map((f) => f.type).join(', ')}}';
}

/// One parameter of a [DCFuncPtr]: its type, and whether the function
/// behind the pointer CONSUMES it (spec §3.2 item 2's `@owned`) or merely
/// borrows it.
///
/// `owned` sits on the TYPE, not on the call site, and that placement is
/// the entire point of ADR-0060 — see [DCFuncPtr].
final class DCFuncParam {
  final DCType type;
  final bool owned;
  const DCFuncParam(this.type, {required this.owned});

  @override
  bool operator ==(Object other) =>
      other is DCFuncParam && other.type == type && other.owned == owned;

  @override
  int get hashCode => Object.hash(DCFuncParam, type, owned);
}

/// A pointer to a function (ADR-0060). What a closure, a callback or a
/// torn-off function name IS as a value, and the operand type
/// `IndirectCall` (instructions.dart) requires.
///
/// **Ownership is part of the type.** `params` records, per parameter,
/// whether the callee consumes it — so two function pointers with the same
/// Dart signature but different ARC conventions are DIFFERENT DCTypes and
/// cannot be assigned to one another. This is not decoration:
///
/// `Call.argOwnership` exists so dc-elide can tell a load-bearing borrowed
/// retain/release pair apart from a redundant owned-consuming one
/// (docs/decisions/0031-move-semantics.md). `dcc-lower` computes it from the
/// callee's declaration. For a call through a VALUE there is no declaration
/// to read, and the fact is not conservatively derivable — it is not
/// derivable at all (docs/escalations/0008 §3). Assuming "borrowed" would
/// make every indirect call an elision barrier, which is how "closures are
/// slow in DCDart" becomes a fact about the language instead of a fact about
/// a missing analysis.
///
/// Recording it on the pointer's type instead moves the question to where
/// the answer IS known: a function pointer is only ever created from a named
/// function (`FuncRef`), and there the declaration is in hand. Every later
/// use — assignment, parameter passing, the call itself — carries the
/// convention with it, checked by ordinary DCType equality, so an indirect
/// call knows its arguments' ownership exactly as a direct call does.
///
/// **NO VARIANCE, deliberately.** Neither direction is safe, so `==` is
/// exact in `owned` as well as in `type`:
///   - owned pointer through a borrowed-typed slot: the caller keeps its own
///     reference and releases it, the callee also releases → double release.
///   - borrowed pointer through an owned-typed slot: the caller retains
///     before the call, nothing ever releases that retain → leak.
/// A subtype lattice on ARC conventions would be a memory-model change
/// (CLAUDE.md rule 4), not an implementation convenience.
///
/// **Not `DCPointer(...)` of something.** A `DCPointer` is `Load`/`Store`
/// -able and points at data with a layout; code has neither. Keeping them
/// distinct is the same reasoning `DCHeapPointer` already uses to stop
/// `Retain` being handed a raw pointer.
///
/// At the LLVM level this is a plain opaque `ptr`, like every other pointer
/// here; the signature is carried by the `IndirectCall` that uses it, which
/// is exactly how LLVM's own opaque-pointer call syntax works.
final class DCFuncPtr extends DCType {
  final List<DCFuncParam> params;
  final DCType returnType;
  const DCFuncPtr(this.params, this.returnType);

  /// Per-parameter ownership, in the shape `Call.argOwnership` uses, so a
  /// consumer (dc-elide) can treat a direct and an indirect call through one
  /// code path.
  List<bool> get paramOwnership =>
      params.map((p) => p.owned).toList(growable: false);

  @override
  bool operator ==(Object other) {
    if (other is! DCFuncPtr) return false;
    if (other.returnType != returnType) return false;
    if (other.params.length != params.length) return false;
    for (var i = 0; i < params.length; i = i + 1) {
      if (other.params[i] != params[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(DCFuncPtr, returnType, Object.hashAll(params));

  @override
  String toString() {
    final ps = params
        .map((p) => p.owned ? '@owned ${p.type}' : '${p.type}')
        .join(', ');
    return 'DCFuncPtr($returnType Function($ps))';
  }
}
