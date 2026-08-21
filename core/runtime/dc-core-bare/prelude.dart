// core/runtime/dc-core-bare/prelude.dart
//
// M0/M1's minimal syntax surface (see core/docs/decisions/0008-m0-frontend-strategy.md,
// 0010-pointer-load-store.md). Lets real, UNMODIFIED, vendored pkg/front_end parse and
// type-check DCDart-shaped source (`@bare u64 add(u64 a, u64 b) => a + b;`,
// `Pointer<u32>.fromAddress(addr).value`) with zero source changes to front_end
// itself. This is NOT the real DCDart CFE fork DCDART_SPEC.md §1 ultimately wants
// (true builtin syntax needing no import, real @bare semantic enforcement) --
// see ADR-0008 for why this is the right first step and what it defers to a real
// front_end fork.
//
// core/dcc-lower reads this library's declarations back out of the Kernel IR it
// produces (verified empirically, not guessed -- see ADR-0008, ADR-0010): `@bare`
// becomes a `ConstantExpression` annotation wrapping an `InstanceConstant` of
// `_Bare`; `u64`/`u32` become real `ExtensionType` DartType nodes; `a + b` becomes
// a `StaticInvocation` of the extension type's synthesized `|+` member;
// `Pointer<T>.fromAddress(x)` becomes a `ConstructorInvocation`;
// `p.value`/`p.value = x` become `InstanceGet`/`InstanceSet`. dcc-lower matches
// every one of these by name AND by this library's URI, so an unrelated
// user-defined type/member elsewhere can never be misread as DCDart syntax.
//
// IMPORTANT: none of these Dart-level method/operator BODIES are ever executed.
// dcc-lower recognizes the *shape* of a call/access in Kernel IR (which class,
// which library, which member name) and substitutes its own DC-IR instructions
// -- it does not read or lower the body expressions below. They exist only so
// real front_end has something type-correct to check DCDart source against.
// `throw UnimplementedError(...)` bodies are deliberate for exactly this reason:
// a body that looks like it does real work would be misleading about what
// actually determines DCDart's semantics (dcc-lower's pattern matching, not this
// file's Dart code).

/// Marks a top-level function `@bare` (DCDART_SPEC.md §2). dcc-lower's ONLY use of
/// this annotation for M0 is "does this function exist for DC-IR purposes at all" --
/// none of @bare's real semantics (no allocator, no exceptions, no ORC) are enforced
/// here or by dcc-lower yet. Real enforcement needs an actual front_end fork (a
/// dedicated diagnostic pass rejecting `throw`/allocation/etc. inside @bare bodies),
/// which is M1+ work, not M0's.
class _Bare {
  const _Bare();
}

const bare = _Bare();

/// Marks a top-level declaration as an EXTERNAL C-ABI symbol that this
/// compilation unit calls but does not define (DCDART_SPEC.md §9: "C ABI is
/// the native ABI... `extern` declarations bind directly"). See
/// docs/decisions/0038-extern-symbols-and-linking.md.
///
/// Usage — the annotation and Dart's own `external` keyword are BOTH
/// required, and dcc-lower rejects either one without the other:
///
/// ```dart
/// @extern
/// external u64 dcx_c_add(u64 a, u64 b);
/// ```
///
/// `external` is Dart's own word for "declared here, defined elsewhere", so
/// front_end already enforces that the declaration has no body and Kernel IR
/// already records it as `Procedure.isExternal` — no new Kernel node, no
/// front_end change (CLAUDE.md rule 2). The `@extern` annotation on top of it
/// is what makes the DECLARATION SET explicit, greppable, and mechanically
/// collectable, which is what `scripts/verify-freestanding.sh` now
/// cross-checks the object file's undefined symbols against (CLAUDE.md rule
/// 1, docs/escalations/0003-extern-c-calls-vs-freestanding.md).
///
/// The Dart identifier IS the C symbol name. There is no `@linkName` yet —
/// nothing has needed a C name that isn't a legal Dart identifier. Add it
/// against a real case, not speculatively.
///
/// SCOPE, deliberately narrow: parameter and return types may be
/// `u8`/`u16`/`u32`/`u64`/`Result`/`void` only. An ARC-managed `HeapObject`
/// or `Weak<T>` in an extern signature is REJECTED — handing a refcounted
/// pointer to a C function raises an ownership-convention question (does the
/// callee consume it? borrow it? retain it?) that nothing has decided, and
/// guessing would be a memory-model change made silently (CLAUDE.md rule 4).
class _Extern {
  const _Extern();
}

const extern = _Extern();

/// u64 (DCDART_SPEC.md §4.1). Surface: construction and `+` -- no other
/// operators yet, because nothing built so far needs them (see
/// core/dc-ir/instructions.dart's identical discipline).
///
/// Backed by a plain `int`. Extension types erase to their representation type
/// at the value level but keep a distinct static type in Kernel IR -- exactly the
/// hook dcc-lower needs to tell "this is a u64" apart from "this is an int"
/// without touching front_end's source.
///
/// `_value + other._value` here is never executed (see this file's header) --
/// dcc-lower emits its own `IAdd(overflow: Overflow.trapping)` for any
/// recognized `u64|+` call, and core/backend really does emit trapping codegen
/// for it now (ADR-0009). This body's plain `+` is only here to type-check.
extension type const u64(int _value) {
  u64 operator +(u64 other) => u64(_value + other._value);

  /// Added for M1's `Result<T,E>`/`?` exit criterion (ADR-0010 [sic --
  /// see docs/decisions/0015-result-and-if-lowering.md]) — an `if`
  /// statement's condition is real Dart `bool`, but nothing here needs to
  /// inspect that type: dcc-lower recognizes the `u64|<` call shape and
  /// assigns `DCBool` directly, the same way `u64|+`'s result is assigned
  /// `DCInt.u64` directly, without ever consulting front_end's inferred
  /// type. `<` only (not `>`/`<=`/`>=`) because nothing built so far needs
  /// the others — same discipline as every other prelude member.
  bool operator <(u64 other) => _value < other._value;

  /// Added for M2's recursion-verification target (docs/decisions/0026-
  /// recursion.md) -- a countdown recursive call (`sumBoxValues(n - u64(1))`)
  /// needs SOME way to make progress toward its base case, and `dcc-lower`
  /// lowers this to `ISub` (`core/dc-ir/instructions.dart`), which has had
  /// real backend codegen since M0 (included alongside `IAdd` from the
  /// start, per that file's own "arithmetic is inseparable as a
  /// vocabulary" note) but no source-level operator wired to it until now.
  u64 operator -(u64 other) => u64(_value - other._value);

  /// Added for oscortex_core's interrupts milestone (IDT entry field
  /// packing, PIC remap bit manipulation, UART status-register polling --
  /// `docs/known-gaps.md`'s former GAP-0006/GAP-0002 notes). Lowers to
  /// `IAnd`/`IOr`/`IXor`/`IShl`/`IShr` (`core/dc-ir/instructions.dart`) --
  /// no overflow-trap semantics apply to bit manipulation (spec §4.1's
  /// traps are for `+`/`-`/`*` only). `>>` only, not the Dart-specific
  /// `>>>` triple-shift operator: every DCDart sized-int type today is
  /// unsigned (see this file), so arithmetic vs. logical right-shift are
  /// the same operation and there's nothing for `>>>` to distinguish yet
  /// -- add it if/when a signed sized-int type gets real prelude support.
  u64 operator &(u64 other) => u64(_value & other._value);
  u64 operator |(u64 other) => u64(_value | other._value);
  u64 operator ^(u64 other) => u64(_value ^ other._value);
  u64 operator <<(u64 other) => u64(_value << other._value);
  u64 operator >>(u64 other) => u64(_value >> other._value);

  /// Comparison and multiplication, completed across all four sized-int
  /// widths (docs/decisions/0035-complete-integer-operators.md). Until this
  /// landed the language had `<` on u64 ONLY, and no `*` at all, which is
  /// why `examples/demo-collatz/collatz.dart` had to spell `3 * n` as
  /// `n + n + n` and halving as `n >> u64(1)`.
  ///
  /// Every one of these was already fully supported downstream and simply
  /// had no source-level operator wired to it: `IMul` has existed in
  /// `core/dc-ir/instructions.dart` since M0 with real `llvm_emit` codegen,
  /// and `ICmpPredicate` has carried all ten predicates
  /// (`eq`/`ne`/`ult`/`ule`/`ugt`/`uge`/`slt`/`sle`/`sgt`/`sge`) just as
  /// long. So this is a frontend-recognition change, not new codegen.
  ///
  /// `*` traps on overflow like `+`/`-` (spec §4.1). The comparisons use the
  /// UNSIGNED predicates, which is correct because every sized-int type the
  /// prelude exposes today is unsigned; a signed type would need the
  /// `s`-prefixed predicates chosen from the operand's own signedness.
  u64 operator *(u64 other) => u64(_value * other._value);
  bool operator <=(u64 other) => _value <= other._value;
  bool operator >(u64 other) => _value > other._value;
  bool operator >=(u64 other) => _value >= other._value;

  /// Integer division and remainder (ADR-0036). `~/` is Dart's INTEGER
  /// division operator; plain `/` in Dart returns a `double`, and DCDart
  /// has no floating point, so `~/` is the honest spelling rather than
  /// redefining `/` to mean something Dart users would read as float
  /// division. Both TRAP on a zero divisor -- LLVM treats `udiv x, 0` as
  /// undefined behaviour, so the backend emits an explicit check.
  u64 operator ~/(u64 other) => u64(_value ~/ other._value);
  u64 operator %(u64 other) => u64(_value % other._value);

  /// Explicit width conversion, DCDART_SPEC.md §4.1: "No implicit widening
  /// or narrowing. `u8 -> u32` requires `.toU32()`. Explicit is the entire
  /// point." Lowers to `IConvert` (ADR-0037), i.e. `zext` when widening and
  /// `trunc` when narrowing; narrowing discards the high bits WITHOUT
  /// trapping, because writing `.toU8()` is itself the statement that you
  /// meant to.
  ///
  /// Found missing by writing `examples/demo-stats/stats.dart`: summing a
  /// `u32` array into a `u64` accumulator is impossible without this, and
  /// there was no way to express it at all -- the representation field is
  /// library-private, so not even a cast could get around it.
  u8 toU8() => u8(_value);
  u16 toU16() => u16(_value);
  u32 toU32() => u32(_value);
  u64 toU64() => u64(_value);
}

/// u32 (DCDART_SPEC.md §4.1). Added for M1's `Pointer<u32>` exit criterion
/// (ADR-0010). `&`/`|`/`^`/`<<`/`>>` added alongside u64's (same reasons,
/// see u64's own doc comment) -- IDT/GDT entry fields are commonly u32.
extension type const u32(int _value) {
  u32 operator &(u32 other) => u32(_value & other._value);
  u32 operator |(u32 other) => u32(_value | other._value);
  u32 operator ^(u32 other) => u32(_value ^ other._value);
  u32 operator <<(u32 other) => u32(_value << other._value);
  u32 operator >>(u32 other) => u32(_value >> other._value);

  /// Comparison and multiplication, completed across all four sized-int
  /// widths (docs/decisions/0035-complete-integer-operators.md). Until this
  /// landed the language had `<` on u64 ONLY, and no `*` at all, which is
  /// why `examples/demo-collatz/collatz.dart` had to spell `3 * n` as
  /// `n + n + n` and halving as `n >> u64(1)`.
  ///
  /// Every one of these was already fully supported downstream and simply
  /// had no source-level operator wired to it: `IMul` has existed in
  /// `core/dc-ir/instructions.dart` since M0 with real `llvm_emit` codegen,
  /// and `ICmpPredicate` has carried all ten predicates
  /// (`eq`/`ne`/`ult`/`ule`/`ugt`/`uge`/`slt`/`sle`/`sgt`/`sge`) just as
  /// long. So this is a frontend-recognition change, not new codegen.
  ///
  /// `*` traps on overflow like `+`/`-` (spec §4.1). The comparisons use the
  /// UNSIGNED predicates, which is correct because every sized-int type the
  /// prelude exposes today is unsigned; a signed type would need the
  /// `s`-prefixed predicates chosen from the operand's own signedness.
  u32 operator +(u32 other) => u32(_value + other._value);
  u32 operator -(u32 other) => u32(_value - other._value);
  u32 operator *(u32 other) => u32(_value * other._value);
  bool operator <(u32 other) => _value < other._value;
  bool operator <=(u32 other) => _value <= other._value;
  bool operator >(u32 other) => _value > other._value;
  bool operator >=(u32 other) => _value >= other._value;

  /// Integer division and remainder (ADR-0036). `~/` is Dart's INTEGER
  /// division operator; plain `/` in Dart returns a `double`, and DCDart
  /// has no floating point, so `~/` is the honest spelling rather than
  /// redefining `/` to mean something Dart users would read as float
  /// division. Both TRAP on a zero divisor -- LLVM treats `udiv x, 0` as
  /// undefined behaviour, so the backend emits an explicit check.
  u32 operator ~/(u32 other) => u32(_value ~/ other._value);
  u32 operator %(u32 other) => u32(_value % other._value);

  /// Explicit width conversion, DCDART_SPEC.md §4.1: "No implicit widening
  /// or narrowing. `u8 -> u32` requires `.toU32()`. Explicit is the entire
  /// point." Lowers to `IConvert` (ADR-0037), i.e. `zext` when widening and
  /// `trunc` when narrowing; narrowing discards the high bits WITHOUT
  /// trapping, because writing `.toU8()` is itself the statement that you
  /// meant to.
  ///
  /// Found missing by writing `examples/demo-stats/stats.dart`: summing a
  /// `u32` array into a `u64` accumulator is impossible without this, and
  /// there was no way to express it at all -- the representation field is
  /// library-private, so not even a cast could get around it.
  u8 toU8() => u8(_value);
  u16 toU16() => u16(_value);
  u32 toU32() => u32(_value);
  u64 toU64() => u64(_value);
}

/// u8 (DCDART_SPEC.md §4.1). Added for M1's `@packed` struct exit criterion
/// (ADR-0011). `&`/`|`/`^`/`<<`/`>>` added alongside u64's (same reasons)
/// -- UART/PIC register values are u8.
extension type const u8(int _value) {
  u8 operator &(u8 other) => u8(_value & other._value);
  u8 operator |(u8 other) => u8(_value | other._value);
  u8 operator ^(u8 other) => u8(_value ^ other._value);
  u8 operator <<(u8 other) => u8(_value << other._value);
  u8 operator >>(u8 other) => u8(_value >> other._value);

  /// Comparison and multiplication, completed across all four sized-int
  /// widths (docs/decisions/0035-complete-integer-operators.md). Until this
  /// landed the language had `<` on u64 ONLY, and no `*` at all, which is
  /// why `examples/demo-collatz/collatz.dart` had to spell `3 * n` as
  /// `n + n + n` and halving as `n >> u64(1)`.
  ///
  /// Every one of these was already fully supported downstream and simply
  /// had no source-level operator wired to it: `IMul` has existed in
  /// `core/dc-ir/instructions.dart` since M0 with real `llvm_emit` codegen,
  /// and `ICmpPredicate` has carried all ten predicates
  /// (`eq`/`ne`/`ult`/`ule`/`ugt`/`uge`/`slt`/`sle`/`sgt`/`sge`) just as
  /// long. So this is a frontend-recognition change, not new codegen.
  ///
  /// `*` traps on overflow like `+`/`-` (spec §4.1). The comparisons use the
  /// UNSIGNED predicates, which is correct because every sized-int type the
  /// prelude exposes today is unsigned; a signed type would need the
  /// `s`-prefixed predicates chosen from the operand's own signedness.
  u8 operator +(u8 other) => u8(_value + other._value);
  u8 operator -(u8 other) => u8(_value - other._value);
  u8 operator *(u8 other) => u8(_value * other._value);
  bool operator <(u8 other) => _value < other._value;
  bool operator <=(u8 other) => _value <= other._value;
  bool operator >(u8 other) => _value > other._value;
  bool operator >=(u8 other) => _value >= other._value;

  /// Integer division and remainder (ADR-0036). `~/` is Dart's INTEGER
  /// division operator; plain `/` in Dart returns a `double`, and DCDart
  /// has no floating point, so `~/` is the honest spelling rather than
  /// redefining `/` to mean something Dart users would read as float
  /// division. Both TRAP on a zero divisor -- LLVM treats `udiv x, 0` as
  /// undefined behaviour, so the backend emits an explicit check.
  u8 operator ~/(u8 other) => u8(_value ~/ other._value);
  u8 operator %(u8 other) => u8(_value % other._value);

  /// Explicit width conversion, DCDART_SPEC.md §4.1: "No implicit widening
  /// or narrowing. `u8 -> u32` requires `.toU32()`. Explicit is the entire
  /// point." Lowers to `IConvert` (ADR-0037), i.e. `zext` when widening and
  /// `trunc` when narrowing; narrowing discards the high bits WITHOUT
  /// trapping, because writing `.toU8()` is itself the statement that you
  /// meant to.
  ///
  /// Found missing by writing `examples/demo-stats/stats.dart`: summing a
  /// `u32` array into a `u64` accumulator is impossible without this, and
  /// there was no way to express it at all -- the representation field is
  /// library-private, so not even a cast could get around it.
  u8 toU8() => u8(_value);
  u16 toU16() => u16(_value);
  u32 toU32() => u32(_value);
  u64 toU64() => u64(_value);
}

/// u16 (DCDART_SPEC.md §4.1). Added for `Port.outb`/`Port.inb` below
/// (oscortex_core's M0 escalation, docs/decisions/0029-port-io.md) -- x86's
/// port address space is 16 bits, so a port number genuinely needs this
/// width, not u8 (too narrow, ports go up to 0xFFFF) or u32 (wider than the
/// real hardware operand). `&`/`|`/`^`/`<<`/`>>` added alongside u64's
/// (same reasons) -- some IDT/GDT fields are u16 (segment selectors,
/// GDTR/IDTR limits).
extension type const u16(int _value) {
  u16 operator &(u16 other) => u16(_value & other._value);
  u16 operator |(u16 other) => u16(_value | other._value);
  u16 operator ^(u16 other) => u16(_value ^ other._value);
  u16 operator <<(u16 other) => u16(_value << other._value);
  u16 operator >>(u16 other) => u16(_value >> other._value);

  /// Comparison and multiplication, completed across all four sized-int
  /// widths (docs/decisions/0035-complete-integer-operators.md). Until this
  /// landed the language had `<` on u64 ONLY, and no `*` at all, which is
  /// why `examples/demo-collatz/collatz.dart` had to spell `3 * n` as
  /// `n + n + n` and halving as `n >> u64(1)`.
  ///
  /// Every one of these was already fully supported downstream and simply
  /// had no source-level operator wired to it: `IMul` has existed in
  /// `core/dc-ir/instructions.dart` since M0 with real `llvm_emit` codegen,
  /// and `ICmpPredicate` has carried all ten predicates
  /// (`eq`/`ne`/`ult`/`ule`/`ugt`/`uge`/`slt`/`sle`/`sgt`/`sge`) just as
  /// long. So this is a frontend-recognition change, not new codegen.
  ///
  /// `*` traps on overflow like `+`/`-` (spec §4.1). The comparisons use the
  /// UNSIGNED predicates, which is correct because every sized-int type the
  /// prelude exposes today is unsigned; a signed type would need the
  /// `s`-prefixed predicates chosen from the operand's own signedness.
  u16 operator +(u16 other) => u16(_value + other._value);
  u16 operator -(u16 other) => u16(_value - other._value);
  u16 operator *(u16 other) => u16(_value * other._value);
  bool operator <(u16 other) => _value < other._value;
  bool operator <=(u16 other) => _value <= other._value;
  bool operator >(u16 other) => _value > other._value;
  bool operator >=(u16 other) => _value >= other._value;

  /// Integer division and remainder (ADR-0036). `~/` is Dart's INTEGER
  /// division operator; plain `/` in Dart returns a `double`, and DCDart
  /// has no floating point, so `~/` is the honest spelling rather than
  /// redefining `/` to mean something Dart users would read as float
  /// division. Both TRAP on a zero divisor -- LLVM treats `udiv x, 0` as
  /// undefined behaviour, so the backend emits an explicit check.
  u16 operator ~/(u16 other) => u16(_value ~/ other._value);
  u16 operator %(u16 other) => u16(_value % other._value);

  /// Explicit width conversion, DCDART_SPEC.md §4.1: "No implicit widening
  /// or narrowing. `u8 -> u32` requires `.toU32()`. Explicit is the entire
  /// point." Lowers to `IConvert` (ADR-0037), i.e. `zext` when widening and
  /// `trunc` when narrowing; narrowing discards the high bits WITHOUT
  /// trapping, because writing `.toU8()` is itself the statement that you
  /// meant to.
  ///
  /// Found missing by writing `examples/demo-stats/stats.dart`: summing a
  /// `u32` array into a `u64` accumulator is impossible without this, and
  /// there was no way to express it at all -- the representation field is
  /// library-private, so not even a cast could get around it.
  u8 toU8() => u8(_value);
  u16 toU16() => u16(_value);
  u32 toU32() => u32(_value);
  u64 toU64() => u64(_value);
}

/// Marks a top-level `final` field for emission into read-only static data
/// (`.rodata`), DCDART_SPEC.md §6. See docs/decisions/0040-static-rodata.md.
///
/// The declaration MUST be `final` with an explicitly `const` initializer:
///
/// ```dart
/// @rodata final List<u64> memmap = const [u64(4096), u64(8192)];
/// ```
///
/// That exact combination is load-bearing and neither half is stylistic:
///
///   * the `const` INITIALIZER makes the contents known at compile time, so
///     they can be emitted into the object file with no initializer
///     machinery, no init order, and nothing to run at startup -- `@bare` has
///     none of those things.
///   * `final` rather than `const` on the FIELD keeps the declaration's
///     identity. Dart canonicalizes constants component-wide, so two `const`
///     declarations with identical contents are literally the same object
///     before the compiler sees them; two `final`s are not. It is also what
///     keeps the name alive at use sites -- a reference to a `const` is
///     inlined by the frontend, leaving no name to take the address of.
///
/// The cost of that choice, recorded here because it is not obvious: a
/// `const` initializer cannot reference a `final` field, so a `@rodata`
/// table can NEVER hold the address of another `@rodata` table. Internal
/// relocations need the all-`const` form, which trades identity away. See
/// the ADR -- this is the single most important thing to know before
/// extending this feature.
class _Rodata {
  const _Rodata();
}

/// A RELOCATION inside a `@rodata` initializer: one pointer-sized word
/// holding the ADDRESS of another `@rodata` table (ADR-0040).
///
/// Holds the target's NAME as a string, and that indirection is the whole
/// trick. A `const` initializer cannot reference a `final` field —
/// `const [Ref(pointFields)]` is "Not a constant expression" — but it can
/// contain a const STRING that names one. So `@rodata final` keeps the
/// declaration identity that `const` would canonicalize away, AND can still
/// express a table pointing at another table. The two are not the trade-off
/// they first appear to be.
///
/// The name is resolved against this compilation unit's own `@rodata`
/// declarations at lowering time; an unknown name is a compile error, not a
/// dangling symbol.
///
/// ```dart
/// @rodata final List<u64> pointFields = const [u64(0), u64(8)];
/// @rodata final List<Ref> pointDesc   = const [Ref('pointFields')];
/// ```
class Ref {
  final String symbol;
  const Ref(this.symbol);
}

/// See [_Rodata].
const rodata = _Rodata();

/// Addressing static read-only data (ADR-0040).
///
/// Static methods, not an extension type, for the same reason as [Port]:
/// there is no natural receiver. Bodies are never executed -- `dcc-lower`
/// substitutes real codegen, same discipline as `Pointer.fromAddress`.
class Rodata {
  /// The address of a `@rodata` table's FIRST ELEMENT.
  ///
  /// There is no header of any kind in front of it: a `@rodata List<u64>`
  /// emits a bare `[N x i64]`, so this address points straight at element 0.
  /// No length word, no class pointer, nothing to skip.
  ///
  /// Compose with `Pointer<T>.fromAddress` to read:
  ///
  /// ```dart
  /// final p = Pointer<u64>.fromAddress(Rodata.addressOf(memmap) + i * u64(8));
  /// ```
  ///
  /// The `u64(8)` there is a STOPGAP: it restates the element width that
  /// `List<u64>` already declared, with nothing checking the two agree.
  /// `Pointer<T>.elementAt(n)` (DCDART_SPEC.md §6, known-gaps GAP-0051) is
  /// the real fix and derives the stride from `T` in one place.
  static u64 addressOf(Object table) =>
      throw UnimplementedError('dcc-lower substitutes real codegen for this');
}

/// x86 port I/O (DCDART_SPEC.md §6, oscortex_core's M0 escalation --
/// docs/decisions/0029-port-io.md). `outb`/`inb` only (byte-width) --
/// word/dword port I/O (`outw`/`outl`) not added, nothing needs them yet.
///
/// **Privileged (ring-0-only).** Unlike every other prelude member, calling
/// these from a normal Linux userspace process traps (SIGSEGV) -- so
/// dcc-lower's own conformance suite can only verify the emitted codegen
/// SHAPE (structurally), never by actually running the compiled code on the
/// dev host the way every other target's conformance test does. The real
/// end-to-end proof this works happens in oscortex_core's own kernel code,
/// running as real ring-0 code under full-system QEMU emulation.
///
/// Static methods, not an extension type -- there's no natural "port
/// number" value these should be instance methods ON; `Port.outb(port,
/// value)` reads the same way the real x86 mnemonics do (`outb` writes,
/// `inb` reads), and dcc-lower recognizes the static-method-call shape
/// directly (mirrors `Result.ok(...)`'s factory-constructor recognition,
/// just for a plain static method instead).
class Port {
  static void outb(u16 port, u8 value) => throw UnimplementedError('dcc-lower substitutes real codegen for this');
  static u8 inb(u16 port) => throw UnimplementedError('dcc-lower substitutes real codegen for this');

  /// Word (16-bit) and doubleword (32-bit) port I/O (ADR-0045).
  ///
  /// Added because PCI configuration space is only decoded for DOUBLEWORD
  /// accesses -- a byte or word read of CONFIG_DATA does not return what you
  /// want, so `inl`/`outl` are not a convenience there, they are the only
  /// thing that works. `oscortex_core` had a hand-written `portio.S` supplying
  /// exactly these four instructions and nothing else; this deletes it.
  ///
  /// No new DC-IR instruction: `PortOut`/`PortIn` already carry typed
  /// operands, so the width comes from `u8`/`u16`/`u32` and the backend
  /// picks the mnemonic and register constraint from it. Same narrowness
  /// ADR-0029 chose -- fixed inline asm shapes, not general `asm`.
  static void outw(u16 port, u16 value) => throw UnimplementedError('dcc-lower substitutes real codegen for this');
  static u16 inw(u16 port) => throw UnimplementedError('dcc-lower substitutes real codegen for this');
  static void outl(u16 port, u32 value) => throw UnimplementedError('dcc-lower substitutes real codegen for this');
  static u32 inl(u16 port) => throw UnimplementedError('dcc-lower substitutes real codegen for this');
}

/// Pointer<T> (DCDART_SPEC.md §6). M1 minimal surface: `.fromAddress` and
/// `.value` get/set, for `T = u32` only -- dcc-lower recognizes exactly that
/// instantiation (a real generic monomorphizer is bigger M1+ work this one
/// conformance target doesn't need yet; see ADR-0010). A second instantiation
/// (e.g. `Pointer<u64>`) is a straightforward extension to dcc-lower's type
/// matching, not a redesign, once something needs it.
///
/// `Pointer<T>.fromAddress` is a NAMED CONSTRUCTOR, not a static method --
/// that's what makes `Pointer<u32>.fromAddress(addr)` (spec §6's own syntax)
/// valid Dart: `ClassName<TypeArg>.namedCtor(...)` instantiates the class at
/// that type argument, which a static-method call cannot do.
///
/// No `@volatile` semantics yet (spec §6 wants the compiler to never
/// reorder/elide MMIO access) -- core/dc-ir's `Load`/`Store` carry no such
/// guarantee. Flagged as a known gap, not silently assumed handled.
class Pointer<T> {
  // u64, not plain `int`: dcc-lower compiles with --no-link-platform (see
  // kernel_frontend.dart), so a real dart:core::int reference would be an
  // unbound platform class node -- crashes on inspection (verified: Kernel's
  // own Printer throws "Reference to dart:core::int is not bound to an AST
  // node" under this flag). u64 is a LOCAL prelude declaration, always
  // fully bound, so dcc-lower can safely inspect it. Real DCDart's own
  // `Pointer<T>.fromAddress` would take `usize`; u64 is close enough for
  // M1's one conformance target.
  final u64 _address;
  const Pointer.fromAddress(this._address);

  T get value => throw UnimplementedError('dcc-lower substitutes real codegen for this');
  set value(T v) => throw UnimplementedError('dcc-lower substitutes real codegen for this');
}

/// Marks a class `@packed` (DCDART_SPEC.md §6): fields laid out sequentially
/// with no natural-alignment padding, matching a C `struct` compiled with
/// `#pragma pack(1)`/`__attribute__((packed))`. dcc-lower requires this
/// annotation on every `extends Struct` subclass it lowers (M1 does not
/// implement natural-alignment layout at all, packed-only) — see
/// docs/decisions/0011-packed-struct-layout.md.
class _Packed {
  const _Packed();
}

const packed = _Packed();

/// C-layout struct base (DCDART_SPEC.md §6, `extends Struct`). M1 minimal
/// surface: subclasses declare fields as getter/setter PAIRS (not stored
/// Dart fields — see this file's header on why bodies don't matter), which
/// dcc-lower reads back in declaration order to compute `@packed` byte
/// offsets (`docs/decisions/0011-packed-struct-layout.md`).
///
/// A struct "instance" is represented in DC-IR as nothing more than its own
/// base address — `Struct.fromAddress` doesn't wrap it in any container
/// type, it just passes the address through. Field access
/// (`instance.field`) lowers to address-plus-offset pointer arithmetic
/// reusing the exact same DC-IR instructions `Pointer<T>.value` does. This
/// is why `core/dc-ir` needed no new instruction for structs at all.
class Struct {
  final u64 _address;
  const Struct.fromAddress(this._address);
}

/// Result<u64, u64> (DCDART_SPEC.md §5), M1's minimal surface. Represented
/// in DC-IR as a `{tag: u64, payload: u64}` VALUE (`core/backend`'s
/// `MakeStruct`/`ExtractField`, docs/decisions/0014-result-value-representation.md)
/// — NOT spec's heap-allocated `sealed class` hierarchy, which needs ARC/
/// allocator machinery this project hasn't built (M2). tag 0 = Ok(payload),
/// tag 1 = Err(payload). Only one concrete `Result` type exists (not a
/// generic `Result<T,E>`) because nothing built so far needs more than one
/// payload/error type — same discipline as everywhere else in this file.
///
/// `.propagate()` approximates `?` (`docs/escalations/0001-question-mark-syntax.md`
/// — `?` itself is not valid Dart syntax; this is the named-method
/// substitute dcc-lower recognizes instead, the same pattern as `.value`).
/// **Known limitation of the approximation**, stated plainly: real `?`
/// would have Dart's own type checker enforce "only usable inside a
/// function that itself returns a compatible `Result`" via return-type
/// inference. A plain method returning `u64` gets no such enforcement from
/// Dart — `dcc-lower` checks this instead (throws if the enclosing
/// function's declared return type isn't `Result`) and is the only thing
/// standing between misuse and a real bug, unlike with real `?` syntax.
class Result {
  final u64 tag;
  final u64 payload;
  Result._(this.tag, this.payload);

  factory Result.ok(u64 value) => Result._(u64(0), value);
  factory Result.err(u64 error) => Result._(u64(1), error);

  /// Never executed (see this file's header). dcc-lower recognizes this
  /// call and substitutes: extract `tag`; if it's 1 (Err), return this
  /// whole `Result` immediately from the enclosing function; if 0 (Ok),
  /// continue evaluation with the extracted `payload` as this expression's
  /// value.
  u64 propagate() => throw UnimplementedError('dcc-lower substitutes real codegen for this');
}

/// Marks a class as heap-allocated with ARC (DCDART_SPEC.md §3.1). M2's
/// minimal surface (docs/decisions/0016-heap-object-field-access.md):
/// subclasses declare real stored fields (unlike `@packed`/`Struct`'s
/// getter-pair pattern, ADR-0011 — real Dart fields give `dcc-lower`
/// declaration-order `Class.fields` and constructor `FieldInitializer`s to
/// read, which is what a genuine heap object needs). Only the
/// `ThisClass(this.field, ...)` shorthand constructor pattern is handled
/// at M2 — a field initializer that isn't a direct reference to a
/// same-position constructor parameter throws in `dcc-lower`, not
/// silently miscompiles.
///
/// Real allocation (`Alloc`, ADR-0015) and real retain/release insertion
/// happen entirely in `dcc-lower`/`core/backend` — nothing here does
/// anything at the Dart-source level; `HeapObject`'s body is never
/// executed for the same reason every other prelude member's isn't (see
/// this file's header).
class HeapObject {
  const HeapObject();
}

/// Marks a `HeapObject`-typed parameter `@owned` (DCDART_SPEC.md §3.2 item
/// 2: "Function parameters default to *borrowed* (no retain/release at the
/// call). Only `@owned` params transfer."). Every `HeapObject`-typed
/// parameter WITHOUT this annotation is borrowed by default (ADR-0019) --
/// this is the explicit consuming counterpart, resolving the last open
/// item in `docs/known-gaps.md` GAP-0017 (docs/decisions/0021-owned-
/// parameters.md). Spec §3.2 frames borrow-inference/`@owned` under
/// "Elision," but the distinction itself is a source-level ownership
/// contract, not something elision invents — elision's job (M3+, not done
/// here) is proving MORE parameters could safely be treated as borrowed
/// than the source says, and eliding the resulting retain/release pairs;
/// it is not what makes `@owned` mean what it means.
class _Owned {
  const _Owned();
}

const owned = _Owned();

/// Weak<T> (DCDART_SPEC.md §3.3 layer 1, docs/decisions/0023-weak-
/// references.md). Does not keep its target alive; `.value` nils out
/// (returns a null `T`) once the target's strong count reaches zero,
/// which the destructor cascade (ADR-0022) makes a real, observable
/// event. M2 minimal surface: constructed FROM a strong `HeapObject`
/// reference, read back via `.value` — no stored fields of its own, since
/// dcc-lower substitutes real `MakeWeak`/`WeakLoad` codegen for this
/// class's shape entirely (see this file's header) rather than reading
/// any field layout from it, unlike `HeapObject` subclasses.
///
/// `unowned` (spec §3.3's other layer-1 variant, traps instead of nilling
/// on a dead access) is NOT this class and is not implemented yet.
class Weak<T> {
  const Weak.fromStrong(T target);

  T get value => throw UnimplementedError('dcc-lower substitutes real codegen for this');
}
