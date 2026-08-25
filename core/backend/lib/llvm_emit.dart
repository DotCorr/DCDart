// core/backend/lib/llvm_emit.dart
//
// DC-IR -> LLVM IR text emission (DCDART_SPEC.md §1). Implements the target
// designed in core/backend/m0-target.md — read that doc for the *why*
// behind the non-arithmetic choices (unmangled symbol names, `nounwind`, no
// hand-written datalayout).
//
// M1 UPDATE (see docs/decisions/0009-overflow-trap-codegen.md):
// `Overflow.trapping` now emits REAL trapping codegen — DCDART_SPEC.md
// §4.1's "traps in both [debug and release] by default" is a load-bearing
// correctness property, not cosmetic, and M0's original "plain add either
// way" was a documented, temporary simplification (m0-target.md §4 item 2's
// own forward note), not the intended final behavior. `Overflow.wrapping`
// is unchanged: plain `add`/`sub`/`mul` (LLVM's fixed-width integer ops
// already wrap).
//
// M1 UPDATE (see docs/decisions/0010-pointer-load-store.md): DCPointer,
// Load, Store, IntToPtr are now implemented (spec §6, `Pointer<u32>`).
// Opaque `ptr` type (LLVM's only pointer representation since LLVM 15) --
// no `getelementptr`/element-type tracking needed for plain load/store.
// No `volatile` keyword on the emitted load/store yet — spec §6 wants MMIO
// access never reordered/elided by the compiler, and DC-IR's Load/Store
// carry no such marker to honor. Flagged in core/docs/known-gaps.md, not
// silently assumed handled.
//
// M1 UPDATE (see docs/decisions/0012-branch-lowering.md): Branch/CondBranch
// are now implemented. DC-IR's block PARAMETERS (not phi instructions --
// see core/dc-ir/README.md "Why block-parameter SSA, not phi nodes") are
// lowered to real LLVM `phi` nodes here, since LLVM IR itself has no
// block-parameter concept -- this file is where that translation belongs
// (a backend/codegen concern, per DC-IR's own design rationale), not
// core/dc-ir or core/dcc-lower. `core/dcc-lower` does not produce
// multi-block DCFunctions yet (needs a comparison instruction DC-IR
// doesn't have -- see docs/known-gaps.md GAP-0007); this was verified with
// a hand-built DCFunction, independent of dcc-lower, specifically so the
// primitive itself is proven correct before something depends on it.
//
// M1 UPDATE (see docs/decisions/0013-icmp.md): ICmp is now implemented --
// `icmp <pred> <type> %lhs, %rhs`, predicate names matching LLVM's own
// (`eq`/`ne`/`ult`/... ) exactly, no translation table needed.
//
// M2 UPDATE (see docs/decisions/0015-m2-minimal-arc-arena.md,
// 0016-heap-object-field-access.md): Alloc/Retain/Release/PtrOffset now
// have real codegen against a fixed internal arena. DCHeapPointer maps to
// opaque `ptr`, same as DCPointer.
//
// M2 UPDATE (see docs/decisions/0018-function-calls.md): Call now has real
// codegen — a plain LLVM `call`, no vtable/dispatch involved (direct calls
// only).
//
// SCOPE CUT, still: DCInt/DCPointer/DCBool/DCStruct/DCHeapPointer only (no
// float codegen). Call does not yet support DCHeapPointer-typed
// arguments/return (dcc-lower doesn't lower those types for function
// signatures yet — GAP-0017).

import 'package:dc_ir/dc_ir.dart';

// M2 ARC arena constants (docs/decisions/0015-m2-minimal-arc-arena.md).
// Fixed slot size regardless of payload -- a deliberate simplification for
// this first proof, not the real Allocator (spec §12 open decision 2,
// docs/escalations/0002-allocator-threading.md).
const int _arenaSlots = 64;
const int _slotSizeBytes = 64;
const int _headerSizeBytes = 16; // u32 strong + u32 weak + ptr cls, spec §3.1

/// Emits LLVM IR text for [module]. [targetTriple] defaults to the M0
/// target from m0-target.md §1; callers building for the host instead (see
/// core/backend/README's "why ELF can't link natively on Windows" note)
/// should pass `null` to omit the `target triple` line entirely and let the
/// downstream compiler pick its default.
String emitModule(
  DCModule module, {
  String? targetTriple = 'x86_64-unknown-none-elf',
  bool noRedZone = false,
}) {
  final declaredIntrinsics = <String>{};
  final functionBuffers = <String>[];
  for (final function in module.functions) {
    functionBuffers.add(_emitFunction(function, declaredIntrinsics));
  }

  final needsArena = module.functions.any(
    (f) => f.blocks.any((b) => b.body.any((i) => i is Alloc || i is Retain || i is Release)),
  );

  final buffer = StringBuffer();
  buffer.writeln('; ${module.name} — emitted by core/backend, not hand-written');
  buffer.writeln();
  if (targetTriple != null) {
    buffer.writeln('target triple = "$targetTriple"');
    buffer.writeln();
  }
  // Read-only statics (ADR-0040) before the arena, so a reader sees the
  // module's own data before its runtime scaffolding. Order is not forced by
  // LLVM -- globals and declares may interleave -- this just matches the
  // existing convention.
  if (module.globals.isNotEmpty) {
    for (final global in module.globals) {
      buffer.write(_emitGlobal(global, context: module.name));
    }
    buffer.writeln();
  }
  if (needsArena) {
    buffer.write(_emitArenaGlobals());
  }
  // llvm.trap and the *.with.overflow.* intrinsics are recognized by name --
  // no library symbol backs them (they lower to inline instructions, ud2 /
  // add+seto respectively, on x86_64), but LLVM textual IR still requires a
  // `declare` for any callee, intrinsic or not. Sorted for stable output.
  for (final decl in declaredIntrinsics.toList()..sort()) {
    buffer.writeln(decl);
  }
  if (declaredIntrinsics.isNotEmpty) buffer.writeln();

  // (ADR-0038) External C-ABI symbols. LLVM's textual IR requires a
  // `declare` for any callee — verified, not assumed: an emitted `call
  // @foo` with no `declare @foo` is rejected by clang outright ("use of
  // undefined value '@foo'"), so this loop is what makes an extern call
  // assemble at all. The resulting object carries a real undefined symbol
  // with a real relocation, which is exactly what the linker needs and
  // exactly what `nm -u` reports.
  //
  // NO `#0` (`nounwind`) HERE, unlike every `define` this file emits.
  // `nounwind` on a `define` is a claim about code we compiled and can
  // check. On a `declare` it would be a claim about somebody else's object
  // file — if that C function does unwind, the attribute makes the
  // optimizer's assumption wrong rather than the program merely slow.
  // Omitting it costs nothing here (`-fno-exceptions`/`-fno-unwind-tables`
  // are already passed to clang, compile.dart) and keeps the IR honest.
  if (module.externFunctions.isNotEmpty) {
    for (final extern in module.externFunctions) {
      buffer.writeln(_emitExternDeclaration(extern));
    }
    buffer.writeln();
  }

  for (final fnText in functionBuffers) {
    buffer.write(fnText);
    buffer.writeln();
  }
  // `noredzone` is set on every emitted function for freestanding targets, in
  // addition to clang's `-mno-red-zone` (ADR-0039). Both, deliberately: the
  // flag governs how clang compiles this .ll, while the attribute travels
  // WITH the IR, so the guarantee survives anyone compiling the emitted .ll
  // by hand or through a different driver. A guarantee that only exists in a
  // command line is one command line away from being lost.
  buffer.writeln(
    'attributes #0 = { nounwind${noRedZone ? ' noredzone' : ''} }',
  );
  return buffer.toString();
}

/// One `declare <ret> @name(<params>)` line for an external C-ABI symbol
/// (ADR-0038). Parameter names are omitted — a `declare` carries types only.
String _emitExternDeclaration(DCExternFunction extern) {
  final retType = _llvmType(extern.returnType, context: extern.linkName);
  final params = extern.paramTypes
      .map((t) => _llvmType(t, context: extern.linkName))
      .join(', ');
  return 'declare $retType @${extern.linkName}($params)';
}

/// LLVM label for a DC-IR block. Block 0 keeps the "entry" label M0/M1's
/// already-verified single-block output used (no reason to churn it);
/// every other block is "blk<index>".
String _labelFor(BlockId id) => id.index == 0 ? 'entry' : 'blk${id.index}';

/// One incoming edge to a block-with-params: which predecessor LLVM label
/// branches here, and what argument values it passes (positionally matching
/// the target block's `params`).
class _PredEdge {
  final String fromLabel;
  final List<DCValue> args;
  const _PredEdge(this.fromLabel, this.args);
}

/// Scans every block's terminator (Branch/CondBranch) to find, for each
/// target `BlockId`, every edge that reaches it. Needed because LLVM `phi`
/// nodes must list every incoming edge up front — unlike DC-IR's block
/// params, which are declared without reference to their sources.
///
/// `finalLabelForBlock` maps each DC-IR block's index to the REAL LLVM
/// label its terminator ends up being emitted from — NOT necessarily
/// `_labelFor(block.id)`. Several instructions (`IAdd`/`ISub` overflow
/// trapping, `Alloc`'s OOM check, `Release`'s destructor/free-slot path,
/// `WeakLoad`'s dead/alive split — anything calling `e.startBlock` more
/// than once) internally split ONE DC-IR block into several real LLVM
/// blocks; whichever one is current when the DC-IR terminator is emitted is
/// the true predecessor label a `phi` in a successor block must reference.
/// Using the DC-IR block's own nominal entry label instead is wrong
/// whenever such an instruction precedes the terminator — a real bug this
/// project's own LLVM-verifier check caught building `while`-loop support
/// (ADR-0028): a loop back edge is the first place a non-empty
/// `Branch`/`CondBranch` arg list ever followed a DC-IR block containing
/// arithmetic (`if`/`else` never used the args before this, see `_lowerIf`).
Map<int, List<_PredEdge>> _collectPredecessors(
  DCFunction function,
  Map<int, String> finalLabelForBlock,
) {
  final preds = <int, List<_PredEdge>>{};
  for (final block in function.blocks) {
    if (block.body.isEmpty) continue; // malformed; caught later per-block
    final terminator = block.body.last;
    final fromLabel = finalLabelForBlock[block.id.index] ?? _labelFor(block.id);
    switch (terminator) {
      case Branch():
        preds.putIfAbsent(terminator.target.index, () => []).add(_PredEdge(fromLabel, terminator.args));
      case CondBranch():
        preds.putIfAbsent(terminator.trueTarget.index, () => []).add(_PredEdge(fromLabel, terminator.trueArgs));
        preds.putIfAbsent(terminator.falseTarget.index, () => []).add(_PredEdge(fromLabel, terminator.falseArgs));
      default:
        break;
    }
  }
  return preds;
}

String _emitFunction(DCFunction function, Set<String> declaredIntrinsics) {
  final entryBlock = function.blocks.first;
  final retType = _llvmType(function.returnType, context: function.linkName);
  // Only the entry block's params are the function's formal parameters
  // (DCFunction's own doc: "blocks[0].params ARE the function parameters").
  // They come from `define`'s own arg list, not a phi node -- there is no
  // predecessor to phi from.
  final params = entryBlock.params
      .map((v) => '${_llvmType(v.type, context: function.linkName)} %v${v.id.index}')
      .join(', ');

  final emitter = _FunctionEmitter(function.linkName, declaredIntrinsics);

  // Pass 1: emit every block's real instructions (NOT phi lines yet — see
  // `_collectPredecessors`'s doc comment for why the real predecessor label
  // isn't knowable until after this pass). Record each DC-IR block's TRUE
  // final internal LLVM label as we go.
  final finalLabelForBlock = <int, String>{};
  for (final block in function.blocks) {
    final label = _labelFor(block.id);
    emitter.startBlock(label);

    if (block.body.isEmpty) {
      throw BackendError(
        '"${function.linkName}": block "$label" has no instructions — every '
        'DC-IR block must end in a terminator',
      );
    }
    for (final instruction in block.body) {
      _emitInstruction(instruction, emitter, context: function.linkName);
    }
    finalLabelForBlock[block.id.index] = emitter.lastFinishedLabel;
  }

  // Pass 2: now that every block's real final label is known (including
  // back edges emitted AFTER their target in source order, e.g. a loop
  // header's own body), compute real predecessor edges and prepend each
  // block's phi lines to its OWN nominal entry label — which is always
  // where its params live, regardless of how many internal sub-blocks its
  // body went on to create.
  final predecessors = _collectPredecessors(function, finalLabelForBlock);
  for (final block in function.blocks) {
    if (block.id.index == 0 || block.params.isEmpty) continue;
    final lines = _phiLines(block, predecessors[block.id.index] ?? const [], function.linkName);
    emitter.prependToLabel(_labelFor(block.id), lines);
  }

  final buffer = StringBuffer();
  // No `dso_local`, no explicit calling-convention keyword: LLVM IR's
  // default `define` is external linkage + the target's C calling
  // convention, which is exactly what a `@bare` symbol meant to link
  // against a plain C caller needs (m0-target.md §1's "no `dso_local`" and
  // "no `ccc` keyword needed" notes).
  buffer.writeln('define $retType @${function.linkName}($params) #0 {');
  buffer.write(emitter.render());
  buffer.writeln('}');
  return buffer.toString();
}

/// Builds one `phi` instruction line per block parameter. LLVM requires
/// every `phi` to precede any non-phi instruction in its block — the
/// caller (`_emitFunction`, pass 2) prepends these to the block's own
/// nominal entry label AFTER real emission has determined every real
/// predecessor label (see `_collectPredecessors`'s doc comment for why this
/// can't happen during the same pass that emits the block's own body).
List<String> _phiLines(
  DCBasicBlock block,
  List<_PredEdge> preds,
  String context,
) {
  if (block.params.isEmpty) return const [];
  if (preds.isEmpty) {
    throw BackendError(
      '"$context": block "${_labelFor(block.id)}" has parameters but no '
      'predecessor branches to it — an unreachable block with params is not '
      'a legal DC-IR function (or dcc-lower produced something unexpected)',
    );
  }
  final lines = <String>[];
  for (var i = 0; i < block.params.length; i++) {
    final param = block.params[i];
    final type = _llvmType(param.type, context: context);
    final incoming = preds.map((p) {
      if (i >= p.args.length) {
        throw BackendError(
          '"$context": predecessor "${p.fromLabel}" of "${_labelFor(block.id)}" '
          'passes ${p.args.length} args, block declares ${block.params.length} params',
        );
      }
      final arg = p.args[i];
      if (arg.type != param.type) {
        throw BackendError(
          '"$context": predecessor "${p.fromLabel}" passes arg ${i} of type '
          '${arg.type} for param of type ${param.type} at '
          '"${_labelFor(block.id)}" — DC-IR requires exact type match, no '
          'implicit widening',
        );
      }
      return '[ %v${arg.id.index}, %${p.fromLabel} ]';
    }).join(', ');
    lines.add('%v${param.id.index} = phi $type $incoming');
  }
  return lines;
}

void _emitInstruction(DCInstruction instruction, _FunctionEmitter e, {required String context}) {
  switch (instruction) {
    case ConstInt():
      final type = _llvmType(instruction.dest.type, context: context);
      e.line('%v${instruction.dest.id.index} = add $type ${instruction.bits}, 0');
    case IAdd():
      _emitArith('add', instruction.dest, instruction.lhs, instruction.rhs, instruction.overflow, e, context);
    case ISub():
      _emitArith('sub', instruction.dest, instruction.lhs, instruction.rhs, instruction.overflow, e, context);
    case IMul():
      _emitArith('mul', instruction.dest, instruction.lhs, instruction.rhs, instruction.overflow, e, context);
    case IDiv():
      _emitDivRem('div', instruction.dest, instruction.lhs, instruction.rhs, e, context);
    case IRem():
      _emitDivRem('rem', instruction.dest, instruction.lhs, instruction.rhs, e, context);
    case PtrToInt():
      final destType = _llvmType(instruction.dest.type, context: context);
      e.line(
        '%v${instruction.dest.id.index} = ptrtoint ptr %v${instruction.pointer.id.index} to $destType',
      );
    case NullRef():
      // LLVM's `null` constant. Materialized through a no-op GEP so the
      // result is a real SSA name other instructions can reference, matching
      // how every other value in this backend is produced.
      e.line('%v${instruction.dest.id.index} = getelementptr i8, ptr null, i64 0');
    case IConvert():
      _emitConvert(instruction, e, context);
    case AddressOfGlobal():
      // `ptrtoint` because the surface hands back a u64 that composes with
      // Pointer.fromAddress, rather than a pointer value (ADR-0040).
      final destType = _llvmType(instruction.dest.type, context: context);
      e.line(
        '%v${instruction.dest.id.index} = ptrtoint ptr @${instruction.globalName} to $destType',
      );
    case IAnd():
      _emitBitwise('and', instruction.dest, instruction.lhs, instruction.rhs, e, context);
    case IOr():
      _emitBitwise('or', instruction.dest, instruction.lhs, instruction.rhs, e, context);
    case IXor():
      _emitBitwise('xor', instruction.dest, instruction.lhs, instruction.rhs, e, context);
    case IShl():
      _emitBitwise('shl', instruction.dest, instruction.lhs, instruction.rhs, e, context);
    case IShr():
      // lhs.type's signedness picks lshr (unsigned) vs ashr (arithmetic,
      // sign-extending) -- see IShr's own doc comment (core/dc-ir/
      // instructions.dart) for why this isn't a separate instruction.
      final lhsType = instruction.lhs.type;
      final op = (lhsType is DCInt && lhsType.signed) ? 'ashr' : 'lshr';
      _emitBitwise(op, instruction.dest, instruction.lhs, instruction.rhs, e, context);
    case ICmp():
      final type = _llvmType(instruction.lhs.type, context: context);
      final pred = instruction.predicate.name; // enum names match LLVM's icmp condition codes exactly
      e.line(
        '%v${instruction.dest.id.index} = icmp $pred $type %v${instruction.lhs.id.index}, %v${instruction.rhs.id.index}',
      );
    case MakeStruct():
      _emitMakeStruct(instruction, e, context);
    case ExtractField():
      final structValueType = instruction.struct.type;
      if (structValueType is! DCStruct) {
        throw BackendError(
          '"$context": ExtractField.struct has non-DCStruct type '
          '$structValueType (${structValueType.runtimeType})',
        );
      }
      final structTypeText = _llvmType(structValueType, context: context);
      e.line(
        '%v${instruction.dest.id.index} = extractvalue $structTypeText '
        '%v${instruction.struct.id.index}, ${instruction.fieldIndex}',
      );
    case IntToPtr():
      final addrType = _llvmType(instruction.address.type, context: context);
      e.line('%v${instruction.dest.id.index} = inttoptr $addrType %v${instruction.address.id.index} to ptr');
    case PtrOffset():
      e.line(
        '%v${instruction.dest.id.index} = getelementptr i8, ptr '
        '%v${instruction.base.id.index}, i64 ${instruction.offsetBytes}',
      );
    case Load():
      final type = _llvmType(instruction.dest.type, context: context);
      // `load volatile` is what stops LLVM deleting an MMIO read whose value
      // it thinks it already knows (ADR-0041).
      final vol = instruction.isVolatile ? 'volatile ' : '';
      e.line('%v${instruction.dest.id.index} = load $vol$type, ptr %v${instruction.pointer.id.index}');
    case Store():
      final type = _llvmType(instruction.value.type, context: context);
      final vol = instruction.isVolatile ? 'volatile ' : '';
      e.line('store $vol$type %v${instruction.value.id.index}, ptr %v${instruction.pointer.id.index}');
    case PortOut():
      // AT&T `out{b,w,l} %reg, %dx` -- value into the accumulator ($0), port
      // into {dx} ($1), matching the asm string's operand order exactly. The
      // byte form was verified against a real disassembly before being wired
      // in (ADR-0029); the wider forms follow the identical shape with the
      // mnemonic suffix and accumulator register chosen by width (ADR-0045).
      final outSpec = _portSpec(instruction.value.type, context: context);
      e.line(
        'call void asm sideeffect "out${outSpec.suffix} \$0, \$1", '
        '"{${outSpec.reg}},{dx}"'
        '(${outSpec.llvmType} %v${instruction.value.id.index}, i16 %v${instruction.port.id.index})',
      );
    case PortIn():
      // AT&T `in{b,w,l} %dx, %reg` -- one output (the accumulator, numbered
      // $0 per LLVM's "outputs numbered first" rule) and one input ({dx},
      // $1), so the asm string reads "in $1, $0" to put the source (port)
      // first and the destination second, matching real AT&T syntax.
      final inSpec = _portSpec(instruction.dest.type, context: context);
      e.line(
        '%v${instruction.dest.id.index} = call ${inSpec.llvmType} asm sideeffect '
        '"in${inSpec.suffix} \$1, \$0", "={${inSpec.reg}},{dx}"'
        '(i16 %v${instruction.port.id.index})',
      );
    // Atomics (ADR-0055). `load atomic`/`store atomic` REQUIRE an explicit
    // `align` in LLVM textual IR — unlike a plain load/store, which may omit
    // it — and the alignment must be at least the type's size or LLVM rejects
    // the module. `atomicrmw` does not require one.
    //
    // The rule-1 property these must hold: on every target this project
    // emits for, a naturally-aligned atomic at 1/2/4/8 bytes lowers to a real
    // instruction (`lock xadd`, `xchg`, `mov`), NOT to a `__atomic_*` libcall.
    // A libcall would be an undefined runtime symbol in a `@bare` object and
    // therefore a failed change even with a green suite. The width check
    // below is what keeps that true: it is not defensive tidiness, it is the
    // enforcement point.
    case AtomicLoad():
      final type = _llvmType(instruction.dest.type, context: context);
      final bytes = _atomicWidthBytes(instruction.dest.type, context: context, what: 'AtomicLoad');
      e.line(
        '%v${instruction.dest.id.index} = load atomic $type, ptr '
        '%v${instruction.pointer.id.index} seq_cst, align $bytes',
      );
    case AtomicStore():
      final type = _llvmType(instruction.value.type, context: context);
      final bytes = _atomicWidthBytes(instruction.value.type, context: context, what: 'AtomicStore');
      e.line(
        'store atomic $type %v${instruction.value.id.index}, ptr '
        '%v${instruction.pointer.id.index} seq_cst, align $bytes',
      );
    case AtomicRmw():
      final type = _llvmType(instruction.value.type, context: context);
      _atomicWidthBytes(instruction.value.type, context: context, what: 'AtomicRmw');
      // AtomicOp's names are LLVM's own opcode names (see its doc comment),
      // so there is no mapping table here and none to drift.
      e.line(
        '%v${instruction.dest.id.index} = atomicrmw ${instruction.op.name} ptr '
        '%v${instruction.pointer.id.index}, $type '
        '%v${instruction.value.id.index} seq_cst',
      );
    // Barriers (ADR-0056). `compilerOnly` is NOT an LLVM ordering — there is
    // no `fence` spelling for "constrain the compiler and emit nothing", so
    // it is an empty inline asm with a memory clobber, which is what Linux's
    // `barrier()` is. The other four are real `fence` instructions; three of
    // them emit no machine code on x86-64 because TSO already provides them,
    // and that is expected, not a bug (see ADR-0056's verification section).
    case Fence():
      if (instruction.ordering == DCOrdering.compilerOnly) {
        e.line('call void asm sideeffect "", "~{memory}"()');
      } else {
        final ordering = switch (instruction.ordering) {
          DCOrdering.acquire => 'acquire',
          DCOrdering.release => 'release',
          DCOrdering.acqRel => 'acq_rel',
          DCOrdering.seqCst => 'seq_cst',
          DCOrdering.compilerOnly => throw StateError('handled above'),
        };
        e.line('fence $ordering');
      }
    case Call():
      _emitCall(instruction, e, context);
    case Alloc():
      declareTrapIntrinsic(e.declaredIntrinsics);
      _emitAlloc(instruction, e, context);
    case Retain():
      _emitRetain(instruction, e, context);
    case Release():
      _emitRelease(instruction, e, context);
    case MakeWeak():
      _emitMakeWeak(instruction, e, context);
    case WeakLoad():
      _emitWeakLoad(instruction, e, context);
    case DropWeak():
      _emitDropWeak(instruction, e, context);
    case Return():
      if (instruction.value == null) {
        e.terminate('ret void');
      } else {
        final type = _llvmType(instruction.value!.type, context: context);
        e.terminate('ret $type %v${instruction.value!.id.index}');
      }
    case Branch():
      e.terminate('br label %${_labelFor(instruction.target)}');
    case CondBranch():
      final condType = _llvmType(instruction.cond.type, context: context);
      if (condType != 'i1') {
        throw BackendError(
          '"$context": CondBranch.cond has non-DCBool type '
          '${instruction.cond.type} ($condType) — DC-IR requires the '
          'condition to be typed DCBool (core/dc-ir/types.dart)',
        );
      }
      e.terminate(
        'br i1 %v${instruction.cond.id.index}, '
        'label %${_labelFor(instruction.trueTarget)}, '
        'label %${_labelFor(instruction.falseTarget)}',
      );
  }
}

/// `and`/`or`/`xor`/`shl`/`lshr`/`ashr` -- all plain, single-instruction,
/// never-trapping LLVM ops (spec §4.1's overflow-trap semantics apply to
/// `+`/`-`/`*` only, not bit manipulation), so unlike `_emitArith` this
/// never needs the overflow-intrinsic expansion.
void _emitBitwise(
  String op,
  DCValue dest,
  DCValue lhs,
  DCValue rhs,
  _FunctionEmitter e,
  String context,
) {
  final destType = dest.type;
  if (destType is! DCInt) {
    throw BackendError(
      '"$context": bitwise op on non-DCInt dest $destType (${destType.runtimeType})',
    );
  }
  final type = _llvmType(destType, context: context);
  e.line('%v${dest.id.index} = $op $type %v${lhs.id.index}, %v${rhs.id.index}');
}

void _emitArith(
  String op,
  DCValue dest,
  DCValue lhs,
  DCValue rhs,
  Overflow overflow,
  _FunctionEmitter e,
  String context,
) {
  final destType = dest.type;
  if (destType is! DCInt) {
    throw BackendError(
      '"$context": arithmetic on non-DCInt dest $destType (${destType.runtimeType})',
    );
  }
  final type = _llvmType(destType, context: context);

  if (overflow == Overflow.wrapping) {
    // Plain LLVM fixed-width arithmetic already wraps -- no expansion needed.
    e.line('%v${dest.id.index} = $op $type %v${lhs.id.index}, %v${rhs.id.index}');
    return;
  }

  // Overflow.trapping (DCDART_SPEC.md §4.1, "traps in both by default"):
  // llvm.{u|s}{add|sub|mul}.with.overflow.iN + llvm.trap(), per
  // m0-target.md §4 item 2 -- both are recognized-by-name LLVM intrinsics
  // the backend lowers to inline instructions (add+seto/jo, and ud2
  // respectively, on x86_64), never to an external symbol call. This is
  // exactly what keeps a trapping function freestanding.
  final signPrefix = destType.signed ? 's' : 'u';
  final intrinsicName = 'llvm.$signPrefix$op.with.overflow.$type';
  declareOverflowIntrinsic(e.declaredIntrinsics, intrinsicName, type);

  final tmp = e.freshName('t');
  final ovf = e.freshName('ovf');
  final trapLabel = e.freshLabel('trap');
  final okLabel = e.freshLabel('ok');

  e.line(
    '%$tmp = call {$type, i1} @$intrinsicName($type %v${lhs.id.index}, $type %v${rhs.id.index})',
  );
  e.line('%v${dest.id.index} = extractvalue {$type, i1} %$tmp, 0');
  e.line('%$ovf = extractvalue {$type, i1} %$tmp, 1');
  e.terminate('br i1 %$ovf, label %$trapLabel, label %$okLabel');

  e.startBlock(trapLabel);
  declareTrapIntrinsic(e.declaredIntrinsics);
  e.line('call void @llvm.trap()');
  e.terminate('unreachable');

  e.startBlock(okLabel);
  // dest's value (%v<idx>) was already defined above, before the branch --
  // it dominates okLabel (the only successor that reaches later uses), so
  // later instructions in okLabel referencing %v<idx> are valid SSA.
}

/// `IDiv`/`IRem` -> an explicit zero-divisor check, then `udiv`/`sdiv` or
/// `urem`/`srem`.
///
/// WHY THE CHECK IS NOT OPTIONAL. In LLVM, division by zero is not a
/// hardware fault you can lean on -- `udiv iN %a, 0` is immediate UB and
/// the optimizer is free to delete the surrounding code entirely. DCDart
/// traps by default (spec §4.1), so this emits the compare and the branch
/// itself rather than inheriting whatever the target CPU happens to do.
///
/// Block-splitting invariant (ADR-0028): this splits one DC-IR block into
/// three real LLVM blocks, so any later `phi` naming this block as a
/// predecessor must name the FINAL label (`okLabel`), not the DC-IR block's
/// nominal label. `_FunctionEmitter.startBlock` is what tracks that, which
/// is exactly why the split goes through it -- the same latent bug ADR-0028
/// fixed for `Alloc`/`Release`/`WeakLoad` would otherwise reappear here.
void _emitDivRem(
  String kind,
  DCValue dest,
  DCValue lhs,
  DCValue rhs,
  _FunctionEmitter e,
  String context,
) {
  final destType = dest.type;
  if (destType is! DCInt) {
    throw BackendError(
      '"$context": $kind on non-DCInt dest $destType (${destType.runtimeType})',
    );
  }
  final type = _llvmType(destType, context: context);

  // Signed division has a SECOND trapping case beyond a zero divisor:
  // INT_MIN / -1 overflows and is UB in LLVM too. Every sized-int type the
  // prelude exposes today is unsigned, so that path is unreachable; it is
  // rejected outright rather than emitted without its guard, so a future
  // signed type cannot silently inherit incorrect codegen (GAP-0024).
  if (destType.signed) {
    throw BackendError(
      '"$context": signed $kind is not implemented. It needs an INT_MIN/-1 '
      'overflow guard in addition to the zero-divisor trap (see '
      'docs/known-gaps.md GAP-0024); emitting it without one would be UB.',
    );
  }

  final isZero = e.freshName('divzero');
  final trapLabel = e.freshLabel('divtrap');
  final okLabel = e.freshLabel('divok');

  e.line('%$isZero = icmp eq $type %v${rhs.id.index}, 0');
  e.terminate('br i1 %$isZero, label %$trapLabel, label %$okLabel');

  e.startBlock(trapLabel);
  declareTrapIntrinsic(e.declaredIntrinsics);
  e.line('call void @llvm.trap()');
  e.terminate('unreachable');

  // The divide itself lands in okLabel, so it is only ever reached with a
  // non-zero divisor -- unlike _emitArith, where the value is computed
  // BEFORE the branch and the trap only rejects it afterwards.
  e.startBlock(okLabel);
  final op = kind == 'div' ? 'udiv' : 'urem';
  e.line('%v${dest.id.index} = $op $type %v${lhs.id.index}, %v${rhs.id.index}');
}

/// `IConvert` -> `zext` / `sext` / `trunc`, chosen from the two types.
///
/// The source's own signedness decides extension: widening a signed value
/// must `sext` to preserve its value, while an unsigned one must `zext`.
/// Getting that backwards is invisible until a negative number is widened,
/// which is why it reads the type rather than taking a flag.
void _emitConvert(IConvert instruction, _FunctionEmitter e, String context) {
  final srcType = instruction.source.type;
  final dstType = instruction.dest.type;
  if (srcType is! DCInt || dstType is! DCInt) {
    throw BackendError(
      '"$context": integer conversion between non-DCInt types '
      '($srcType -> $dstType)',
    );
  }
  final src = _llvmType(srcType, context: context);
  final dst = _llvmType(dstType, context: context);
  final srcBits = _intBits(srcType, context: context);
  final dstBits = _intBits(dstType, context: context);

  if (srcBits == dstBits) {
    // Same width: nothing to convert. Emitted as an `add 0` rather than
    // skipped entirely, because `dest` still has to be a defined SSA name
    // that later instructions can reference.
    e.line('%v${instruction.dest.id.index} = add $dst %v${instruction.source.id.index}, 0');
    return;
  }
  final op = dstBits > srcBits ? (srcType.signed ? 'sext' : 'zext') : 'trunc';
  e.line(
    '%v${instruction.dest.id.index} = $op $src %v${instruction.source.id.index} to $dst',
  );
}

/// Bit width of a `DCInt`. `usize`/`isize` are 64 here because every target
/// in the registry (ADR-0033) is 64-bit; a 32-bit target would have to make
/// this target-dependent rather than a constant.
int _intBits(DCInt type, {required String context}) => switch (type.width) {
      IntWidth.w8 => 8,
      IntWidth.w16 => 16,
      IntWidth.w32 => 32,
      IntWidth.w64 => 64,
      IntWidth.wSize => 64,
    };

/// `MakeStruct` -> a chain of `insertvalue`, starting from `undef`, one per
/// field, matching how LLVM itself expects an aggregate built from scratch
/// (there is no single "construct a struct" instruction in LLVM IR either).
/// The last `insertvalue` writes directly to `dest`; intermediate steps get
/// fresh temp names.
void _emitMakeStruct(MakeStruct instruction, _FunctionEmitter e, String context) {
  final structType = instruction.structType;
  if (instruction.fields.length != structType.fields.length) {
    throw BackendError(
      '"$context": MakeStruct provides ${instruction.fields.length} field '
      'values for a struct type with ${structType.fields.length} fields',
    );
  }
  if (instruction.fields.isEmpty) {
    throw BackendError(
      '"$context": MakeStruct with zero fields — not implemented (no '
      'current use needs an empty struct value; the pointer-backed struct '
      'pattern, ADR-0011, never constructs a DCStruct value at all)',
    );
  }

  final structTypeText = _llvmType(structType, context: context);
  var current = 'undef';
  for (var i = 0; i < instruction.fields.length; i++) {
    final field = instruction.fields[i];
    final expectedType = structType.fields[i].type;
    if (field.type != expectedType) {
      throw BackendError(
        '"$context": MakeStruct field $i has type ${field.type}, struct '
        'type declares ${expectedType} — no implicit widening (same rule '
        'as arithmetic)',
      );
    }
    final fieldType = _llvmType(field.type, context: context);
    final isLast = i == instruction.fields.length - 1;
    final destName = isLast ? 'v${instruction.dest.id.index}' : e.freshName('agg');
    e.line(
      '%$destName = insertvalue $structTypeText $current, $fieldType %v${field.id.index}, $i',
    );
    current = '%$destName';
  }
}

/// `Call`: a plain LLVM `call`, no attributes beyond the module-wide `#0`
/// every `define` already carries. The callee's exact LLVM return type
/// comes from `instruction.dest`'s own type (or `void` if `dest` is
/// `null`) — same "each instruction self-describes its own types, no
/// cross-referencing another function's declaration" pattern every other
/// instruction here follows (e.g. `Return` never looks up the enclosing
/// `DCFunction.returnType` either). Since every `DCFunction` in the module
/// is emitted as a top-level `define` with a stable name
/// (`function.linkName`), and LLVM resolves top-level symbol references in
/// one pass, this works regardless of whether the callee appears earlier
/// or later in the emitted text.
void _emitCall(Call instruction, _FunctionEmitter e, String context) {
  final argsText = instruction.args
      .map((a) => '${_llvmType(a.type, context: context)} %v${a.id.index}')
      .join(', ');
  final dest = instruction.dest;
  if (dest == null) {
    e.line('call void @${instruction.targetName}($argsText)');
    return;
  }
  final retType = _llvmType(dest.type, context: context);
  e.line('%v${dest.id.index} = call $retType @${instruction.targetName}($argsText)');
}

void declareOverflowIntrinsic(Set<String> declared, String name, String type) {
  declared.add('declare {$type, i1} @$name($type, $type)');
}

void declareTrapIntrinsic(Set<String> declared) {
  declared.add('declare void @llvm.trap()');
}

/// Names the backend emits for its own use. A DCDart global taking one of
/// these would produce a duplicate-symbol error at best and silently shadow
/// ARC arena state at worst — `linkName` goes out verbatim (spec §9) with no
/// mangling, so nothing else would catch it.
const _reservedGlobalNames = {'dc_arena', 'dc_free_list', 'dc_free_top'};

/// One `@rodata` global: `@name = internal constant <init>, align N`.
///
/// `internal`, not `private`: private globals emit no symbol at all, which
/// would make the data invisible to `nm` and un-referenceable from C.
/// Internal keeps a real (local) symbol while still not exporting it.
///
/// Deliberately NOT `unnamed_addr`. That moves a global into a mergeable
/// section (verified: `.section .rodata.cst8,"aM",@progbits,8`), which lets
/// the linker collapse two byte-identical globals to ONE ADDRESS. Harmless
/// for name strings; catastrophic for anything whose address means something,
/// which is exactly what a type descriptor's address will mean.
String _emitGlobal(DCGlobal global, {required String context}) {
  if (_reservedGlobalNames.contains(global.linkName)) {
    throw BackendError(
      '"$context": global "${global.linkName}" collides with a name the '
      'backend emits for its own ARC arena. Rename it — symbol names are '
      'emitted verbatim (spec §9), so nothing downstream would catch this.',
    );
  }
  final init = _emitConstant(global.initializer, context: context);
  // `global` (writable) vs `constant` (read-only) is the ONLY difference in
  // the emitted line, and it is the whole difference between .bss and
  // .rodata (ADR-0051). LLVM places a zero-initialized writable global in
  // .bss automatically, where it occupies no space in the object file.
  final kind = global.isMutable ? 'global' : 'constant';
  final buffer = StringBuffer();
  buffer.writeln(
    '@${global.linkName} = internal $kind $init, align ${global.alignBytes}',
  );
  return buffer.toString();
}

/// A [DCConstant] tree as LLVM constant-expression text.
String _emitConstant(DCConstant constant, {required String context}) {
  switch (constant) {
    case DCConstInt(type: final type, value: final value):
      return '${_llvmType(type, context: context)} $value';
    case DCConstArray(elementType: final elementType, elements: final elements):
      // The array's element type comes from the ELEMENTS, not from
      // `elementType`, because a relocation is a `ptr` regardless of the
      // pointer-sized integer type the IR labelled the table with. Getting
      // this from the declared type instead produces
      // "constant expression type mismatch: got '[2 x ptr]' but expected
      // '[2 x i64]'" -- which is at least loud, but only because LLVM
      // type-checks constants.
      final elemType = elements.isEmpty
          ? _llvmType(elementType, context: context)
          : _constantTypeText(elements.first, elementType, context: context);
      for (final element in elements) {
        final t = _constantTypeText(element, elementType, context: context);
        if (t != elemType) {
          throw BackendError(
            '"$context": a constant array mixes element types ($elemType and '
            '$t). An LLVM array is homogeneous; a mixed aggregate needs a '
            'struct, which no source construct produces today.',
          );
        }
      }
      final body = elements
          .map((e) => _emitConstant(e, context: context))
          .join(', ');
      // `[N x T] [T a, T b, ...]` -- each element repeats its own type, which
      // is LLVM's required form for an array constant, not redundancy.
      return '[${elements.length} x $elemType] [$body]';
    case DCZeroInit(bytes: final bytes):
      // `zeroinitializer` rather than an explicit array of zeros: it occupies
      // no space in the object file, which matters at page-table and
      // frame-bitmap sizes (ADR-0051).
      return '[$bytes x i8] zeroinitializer';
    case DCConstStruct(fields: final fields):
      // `{ T1, T2 } { T1 a, T2 b }` -- TYPE then VALUE, the same shape the
      // array case emits. Omitting the leading type gives LLVM's unhelpful
      // "expected '}' at end of struct", because it parses the value as a
      // type. Unpacked, so LLVM applies natural field alignment, matching
      // what a C struct of the same fields does; a @packed equivalent would
      // need `<{ }>`, which no source construct asks for yet.
      final body = fields
          .map((f) => _emitConstant(f, context: context))
          .join(', ');
      final parts = fields
          .map((f) => _constantTypeText(f, DCInt.u64, context: context))
          .join(', ');
      final typeText = '{ $parts }';
      return '$typeText { $body }';
    case DCConstAddrOf(globalName: final name, offsetBytes: final offset):
      // Unreachable from source today (see DCConstAddrOf's doc comment); the
      // dc-ir unit tests construct it directly so this path is exercised.
      if (offset == 0) return 'ptr @$name';
      return 'ptr getelementptr (i8, ptr @$name, i64 $offset)';
  }
}

/// The LLVM type text a [DCConstant] emits itself as.
///
/// A relocation is `ptr` no matter what pointer-sized integer type the
/// enclosing table was labelled with — the label describes the table's
/// stride, the element describes what is actually stored.
String _constantTypeText(
  DCConstant constant,
  DCType fallback, {
  required String context,
}) {
  switch (constant) {
    case DCConstInt(type: final type):
      return _llvmType(type, context: context);
    case DCConstAddrOf():
      return 'ptr';
    case DCZeroInit(bytes: final bytes):
      return '[$bytes x i8]';
    case DCConstStruct(fields: final fields):
      final parts = fields
          .map((f) => _constantTypeText(f, fallback, context: context))
          .join(', ');
      return '{ $parts }';
    case DCConstArray(elements: final elements, elementType: final elementType):
      final inner = elements.isEmpty
          ? _llvmType(elementType, context: context)
          : _constantTypeText(elements.first, elementType, context: context);
      return '[${elements.length} x $inner]';
  }
}

/// The x86 mnemonic suffix, accumulator register and LLVM type for a port
/// access of a given operand width (ADR-0045).
///
/// Port I/O is defined for byte, word and doubleword only — there is no
/// `outq`. A 64-bit operand is rejected here rather than emitted as
/// something clang would refuse later with a worse message.
({String suffix, String reg, String llvmType}) _portSpec(
  DCType type, {
  required String context,
}) {
  if (type is DCInt) {
    switch (type.width) {
      case IntWidth.w8:
        return (suffix: 'b', reg: 'al', llvmType: 'i8');
      case IntWidth.w16:
        return (suffix: 'w', reg: 'ax', llvmType: 'i16');
      case IntWidth.w32:
        return (suffix: 'l', reg: 'eax', llvmType: 'i32');
      case IntWidth.w64:
      case IntWidth.wSize:
        throw BackendError(
          '"$context": port I/O at 64-bit width. x86 defines port access for '
          'byte, word and doubleword only — there is no `outq`/`inq`.',
        );
    }
  }
  throw BackendError(
    '"$context": port I/O on a non-integer operand ($type)',
  );
}

/// The byte width of an atomic operand, and the gate that keeps atomics from
/// becoming a runtime dependency (ADR-0055).
///
/// LLVM lowers an atomic to a real instruction only when the type is an
/// integer of a power-of-two byte size the target supports natively. Outside
/// that set — an `i1`, an `i128` on x86-64, a struct — it emits a call to
/// `__atomic_load`/`__atomic_fetch_add`/… from libatomic. In a `@bare` object
/// that is an undefined runtime symbol, which is a `CLAUDE.md` rule 1
/// violation and a failed change regardless of what the test suite says.
///
/// So this check is not defensive tidiness; it is where that guarantee is
/// enforced. `wSize` is included because both targets this project emits for
/// are 64-bit; a future 32-bit target must revisit it (a 64-bit atomic on
/// i686 is `cmpxchg8b`, still an instruction, but `usize` would no longer
/// mean 8 here).
///
/// The alignment returned equals the width, which is what LLVM requires for
/// an atomic and what every caller in this project satisfies: a `@bss` block
/// declares `align` explicitly (ADR-0051) and a heap payload field sits at a
/// naturally aligned offset. An UNDER-aligned address is undefined behaviour
/// at the hardware level (a `lock` operation spanning a cache line is not
/// atomic on some x86 parts and faults on others) and nothing here can detect
/// it — DC-IR carries no alignment on a `DCPointer`. Recorded in GAP-0042.
int _atomicWidthBytes(
  DCType type, {
  required String context,
  required String what,
}) {
  if (type is DCInt) {
    switch (type.width) {
      case IntWidth.w8:
        return 1;
      case IntWidth.w16:
        return 2;
      case IntWidth.w32:
        return 4;
      case IntWidth.w64:
      case IntWidth.wSize:
        return 8;
    }
  }
  throw BackendError(
    '"$context": $what on a non-integer operand ($type). An atomic must be a '
    'sized integer (u8/u16/u32/u64) — anything else lowers to a `__atomic_*` '
    'libcall, which is an undefined runtime symbol in a @bare object and a '
    'CLAUDE.md rule 1 violation.',
  );
}

/// The M2 ARC arena's global state (docs/decisions/0015): a fixed array of
/// `_arenaSlots` slots, each `_slotSizeBytes` bytes, plus a LIFO free-list
/// (`@dc_free_list`, `@dc_free_top`) of available slot indices. Emitted
/// once per module, only when something in it actually allocates.
String _emitArenaGlobals() {
  final indices = List.generate(_arenaSlots, (i) => 'i32 $i').join(', ');
  final buffer = StringBuffer();
  buffer.writeln('@dc_arena = global [$_arenaSlots x [$_slotSizeBytes x i8]] zeroinitializer');
  buffer.writeln('@dc_free_list = global [$_arenaSlots x i32] [$indices]');
  buffer.writeln('@dc_free_top = global i32 $_arenaSlots');
  buffer.writeln();
  return buffer.toString();
}

/// `Alloc`: pop a free slot (trap if none left — OOM is unrecoverable in
/// this minimal arena, matching spec §5's `panic()` model for `@bare`),
/// write the header (strong=1, weak=0, cls=`destructorName`'s address or
/// null — docs/decisions/0022-destructor-cascade.md), return the payload
/// pointer (header sits at `payload - _headerSizeBytes`).
void _emitAlloc(Alloc instruction, _FunctionEmitter e, String context) {
  final oomLabel = e.freshLabel('allocOom');
  final okLabel = e.freshLabel('allocOk');
  final top = e.freshName('top');
  final empty = e.freshName('empty');

  e.line('%$top = load i32, ptr @dc_free_top');
  e.line('%$empty = icmp eq i32 %$top, 0');
  e.terminate('br i1 %$empty, label %$oomLabel, label %$okLabel');

  e.startBlock(oomLabel);
  e.line('call void @llvm.trap()');
  e.terminate('unreachable');

  e.startBlock(okLabel);
  final newTop = e.freshName('newtop');
  final newTop64 = e.freshName('newtop64');
  final idxPtr = e.freshName('idxptr');
  final idx = e.freshName('idx');
  final idx64 = e.freshName('idx64');
  final slot = e.freshName('slot');
  final weakPtr = e.freshName('weakptr');
  final clsPtr = e.freshName('clsptr');

  e.line('%$newTop = sub i32 %$top, 1');
  e.line('store i32 %$newTop, ptr @dc_free_top');
  e.line('%$newTop64 = sext i32 %$newTop to i64');
  e.line(
    '%$idxPtr = getelementptr [$_arenaSlots x i32], ptr @dc_free_list, i64 0, i64 %$newTop64',
  );
  e.line('%$idx = load i32, ptr %$idxPtr');
  e.line('%$idx64 = sext i32 %$idx to i64');
  e.line(
    '%$slot = getelementptr [$_arenaSlots x [$_slotSizeBytes x i8]], ptr @dc_arena, i64 0, i64 %$idx64',
  );
  e.line('store i32 1, ptr %$slot'); // strong = 1
  e.line('%$weakPtr = getelementptr i8, ptr %$slot, i64 4');
  e.line('store i32 0, ptr %$weakPtr'); // weak = 0
  e.line('%$clsPtr = getelementptr i8, ptr %$slot, i64 8');
  if (instruction.destructorName != null) {
    // cls = the destructor's own address -- a real function symbol, valid
    // as a `ptr` value directly under LLVM's opaque pointers. Not a
    // ClassInfo indirection (no vtable exists, GAP-0003) -- Release reads
    // this back and calls straight through it.
    e.line('store ptr @${instruction.destructorName}, ptr %$clsPtr');
  } else {
    e.line('store ptr null, ptr %$clsPtr'); // no heap-typed fields -- nothing to release on death
  }

  if (instruction.payloadSizeBytes + _headerSizeBytes > _slotSizeBytes) {
    throw BackendError(
      '"$context": Alloc payload ${instruction.payloadSizeBytes} bytes + '
      'header $_headerSizeBytes bytes exceeds the M2 arena\'s fixed slot '
      'size ($_slotSizeBytes bytes) — see docs/decisions/0015-m2-minimal-arc-arena.md',
    );
  }
  e.line(
    '%v${instruction.dest.id.index} = getelementptr i8, ptr %$slot, i64 $_headerSizeBytes',
  );
}

/// `Retain`: increment the strong count at `object - _headerSizeBytes`.
/// Single block — no branching, no OOM/overflow case in this minimal
/// version (not pressured by the M2 leak test; a real implementation would
/// want overflow protection on the count itself).
void _emitRetain(Retain instruction, _FunctionEmitter e, String context) {
  // (ADR-0049) NULL-SAFE. A nullable heap reference may legitimately hold
  // null, and retaining it would read the object header 16 bytes BEFORE
  // address 0 -- a wild read, not a clean fault. Retaining null is a no-op,
  // matching every refcounting runtime that permits null references.
  final isNull = e.freshName('retainnull');
  final doLabel = e.freshLabel('retainDo');
  final doneLabel = e.freshLabel('retainDone');
  e.line('%$isNull = icmp eq ptr %v${instruction.object.id.index}, null');
  e.terminate('br i1 %$isNull, label %$doneLabel, label %$doLabel');

  e.startBlock(doLabel);
  final header = e.freshName('hdr');
  final strong = e.freshName('strong');
  final newStrong = e.freshName('newstrong');
  e.line('%$header = getelementptr i8, ptr %v${instruction.object.id.index}, i64 -$_headerSizeBytes');
  e.line('%$strong = load i32, ptr %$header');
  e.line('%$newStrong = add i32 %$strong, 1');
  e.line('store i32 %$newStrong, ptr %$header');
  e.terminate('br label %$doneLabel');

  e.startBlock(doneLabel);
}

/// Pushes the arena slot containing `headerVar` (a `ptr` SSA name, no `%`
/// prefix) back onto the free list. Shared by `Release` (when a dying
/// object has no outstanding weak references) and `DropWeak` (when the
/// last weak reference to an ALREADY-dead object goes away,
/// docs/decisions/0023-weak-references.md) — both need the exact same
/// slot-index-from-pointer arithmetic, and this is the one place it's
/// written. Emits into whatever block is currently open; does not
/// terminate it (callers branch onward themselves).
void _emitFreeSlotPushback(String headerVar, _FunctionEmitter e) {
  final headerInt = e.freshName('hdrint');
  final arenaInt = e.freshName('arenaint');
  final diff = e.freshName('diff');
  final slotIdx64 = e.freshName('slotidx64');
  final slotIdx32 = e.freshName('slotidx32');
  final top = e.freshName('top');
  final top64 = e.freshName('top64');
  final freeSlotPtr = e.freshName('freeslotptr');
  final newTop = e.freshName('newtop');

  e.line('%$headerInt = ptrtoint ptr %$headerVar to i64');
  e.line('%$arenaInt = ptrtoint ptr @dc_arena to i64');
  e.line('%$diff = sub i64 %$headerInt, %$arenaInt');
  e.line('%$slotIdx64 = udiv i64 %$diff, $_slotSizeBytes');
  e.line('%$slotIdx32 = trunc i64 %$slotIdx64 to i32');
  e.line('%$top = load i32, ptr @dc_free_top');
  e.line('%$top64 = sext i32 %$top to i64');
  e.line(
    '%$freeSlotPtr = getelementptr [$_arenaSlots x i32], ptr @dc_free_list, i64 0, i64 %$top64',
  );
  e.line('store i32 %$slotIdx32, ptr %$freeSlotPtr');
  e.line('%$newTop = add i32 %$top, 1');
  e.line('store i32 %$newTop, ptr @dc_free_top');
}

/// `Release`: decrement the strong count; at zero, run the destructor
/// (docs/decisions/0022-destructor-cascade.md — a direct call through
/// `cls`, set at `Alloc` time, NOT a real `ClassInfo` vtable, since there
/// is no dynamic dispatch yet, GAP-0003), then free the slot -- BUT ONLY
/// if there is no outstanding weak reference (docs/decisions/0023). If
/// `weak > 0`, the slot is left as a "zombie": `strong == 0` (so
/// `WeakLoad` correctly reports the object as dead) but not yet on the
/// free list (so a `WeakLoad` reading stale memory can't happen) — it's
/// `DropWeak`'s job to actually free it once the last weak reference also
/// goes away.
void _emitRelease(Release instruction, _FunctionEmitter e, String context) {
  final header = e.freshName('hdr');
  final strong = e.freshName('strong');
  final newStrong = e.freshName('newstrong');
  final isZero = e.freshName('iszero');
  final freeLabel = e.freshLabel('releaseFree');
  final doneLabel = e.freshLabel('releaseDone');

  // (ADR-0049) NULL-SAFE, same reasoning as `_emitRetain`: releasing null is
  // a no-op rather than a wild read of memory before address 0.
  final relNull = e.freshName('releasenull');
  final liveLabel = e.freshLabel('releaseLive');
  e.line('%$relNull = icmp eq ptr %v${instruction.object.id.index}, null');
  e.terminate('br i1 %$relNull, label %$doneLabel, label %$liveLabel');

  e.startBlock(liveLabel);
  e.line('%$header = getelementptr i8, ptr %v${instruction.object.id.index}, i64 -$_headerSizeBytes');
  e.line('%$strong = load i32, ptr %$header');
  e.line('%$newStrong = sub i32 %$strong, 1');
  e.line('store i32 %$newStrong, ptr %$header');
  e.line('%$isZero = icmp eq i32 %$newStrong, 0');
  e.terminate('br i1 %$isZero, label %$freeLabel, label %$doneLabel');

  e.startBlock(freeLabel);
  final clsPtr = e.freshName('clsptr');
  final clsVal = e.freshName('clsval');
  final hasDtor = e.freshName('hasdtor');
  final dtorLabel = e.freshLabel('releaseDtor');
  final afterDtorLabel = e.freshLabel('releaseAfterDtor');
  e.line('%$clsPtr = getelementptr i8, ptr %$header, i64 8');
  e.line('%$clsVal = load ptr, ptr %$clsPtr');
  e.line('%$hasDtor = icmp ne ptr %$clsVal, null');
  e.terminate('br i1 %$hasDtor, label %$dtorLabel, label %$afterDtorLabel');

  e.startBlock(dtorLabel);
  // Indirect call through the function-pointer VALUE loaded from `cls` --
  // every destructor this project generates has the identical signature
  // `void (ptr)` (docs/decisions/0022), so no per-class type variance to
  // handle here.
  e.line('call void %$clsVal(ptr %v${instruction.object.id.index})');
  e.terminate('br label %$afterDtorLabel');

  e.startBlock(afterDtorLabel);
  final weakPtr = e.freshName('weakptr');
  final weakVal = e.freshName('weakval');
  final noWeak = e.freshName('noweak');
  final freeSlotLabel = e.freshLabel('releaseFreeSlot');
  e.line('%$weakPtr = getelementptr i8, ptr %$header, i64 4');
  e.line('%$weakVal = load i32, ptr %$weakPtr');
  e.line('%$noWeak = icmp eq i32 %$weakVal, 0');
  e.terminate('br i1 %$noWeak, label %$freeSlotLabel, label %$doneLabel');

  e.startBlock(freeSlotLabel);
  _emitFreeSlotPushback(header, e);
  e.terminate('br label %$doneLabel');

  e.startBlock(doneLabel);
}

/// `MakeWeak`: increments the target's `weak` header count (offset 4),
/// leaves `strong` untouched. `dest` is a fresh SSA name for the SAME
/// address as `object` (a zero-offset `getelementptr` -- cheap, and gives
/// `dest` its own definition per DC-IR's "every value defined exactly
/// once" rule even though its runtime value is identical).
void _emitMakeWeak(MakeWeak instruction, _FunctionEmitter e, String context) {
  final header = e.freshName('hdr');
  final weakPtr = e.freshName('weakptr');
  final weakVal = e.freshName('weakval');
  final newWeak = e.freshName('newweak');
  e.line('%$header = getelementptr i8, ptr %v${instruction.object.id.index}, i64 -$_headerSizeBytes');
  e.line('%$weakPtr = getelementptr i8, ptr %$header, i64 4');
  e.line('%$weakVal = load i32, ptr %$weakPtr');
  e.line('%$newWeak = add i32 %$weakVal, 1');
  e.line('store i32 %$newWeak, ptr %$weakPtr');
  e.line(
    '%v${instruction.dest.id.index} = getelementptr i8, ptr %v${instruction.object.id.index}, i64 0',
  );
}

/// `WeakLoad`: checks `strong`; dead (zero) -> `dest` is the null pointer,
/// no retain; alive (nonzero) -> retains (increments `strong`) and `dest`
/// is the live address. Both paths converge via a real `phi` (this
/// instruction's internal block expansion needs one explicitly -- unlike
/// the DC-IR block-parameter phis `_phiLines` handles, this is purely
/// an artifact of ONE instruction needing two different values on two
/// paths, with no DC-IR-level block boundary involved).
void _emitWeakLoad(WeakLoad instruction, _FunctionEmitter e, String context) {
  final header = e.freshName('hdr');
  final strongVal = e.freshName('strongval');
  final isDead = e.freshName('isdead');
  final deadLabel = e.freshLabel('weakDead');
  final aliveLabel = e.freshLabel('weakAlive');
  final doneLabel = e.freshLabel('weakDone');

  e.line('%$header = getelementptr i8, ptr %v${instruction.weak.id.index}, i64 -$_headerSizeBytes');
  e.line('%$strongVal = load i32, ptr %$header');
  e.line('%$isDead = icmp eq i32 %$strongVal, 0');
  e.terminate('br i1 %$isDead, label %$deadLabel, label %$aliveLabel');

  e.startBlock(deadLabel);
  e.terminate('br label %$doneLabel');

  e.startBlock(aliveLabel);
  final newStrong = e.freshName('newstrong');
  e.line('%$newStrong = add i32 %$strongVal, 1');
  e.line('store i32 %$newStrong, ptr %$header');
  e.terminate('br label %$doneLabel');

  e.startBlock(doneLabel);
  e.line(
    '%v${instruction.dest.id.index} = phi ptr [ null, %$deadLabel ], '
    '[ %v${instruction.weak.id.index}, %$aliveLabel ]',
  );
}

/// `DropWeak`: decrements `weak`; if it's now zero AND `strong` is also
/// zero (the target already died while this weak reference was still
/// outstanding, docs/decisions/0023), finally frees the slot `Release`
/// deliberately left as a zombie. If `strong` is nonzero, the target is
/// still alive (through some other strong reference) -- nothing to free.
void _emitDropWeak(DropWeak instruction, _FunctionEmitter e, String context) {
  final header = e.freshName('hdr');
  final weakPtr = e.freshName('weakptr');
  final weakVal = e.freshName('weakval');
  final newWeak = e.freshName('newweak');
  final isZero = e.freshName('iszero');
  final checkStrongLabel = e.freshLabel('dropWeakCheckStrong');
  final doneLabel = e.freshLabel('dropWeakDone');

  e.line('%$header = getelementptr i8, ptr %v${instruction.object.id.index}, i64 -$_headerSizeBytes');
  e.line('%$weakPtr = getelementptr i8, ptr %$header, i64 4');
  e.line('%$weakVal = load i32, ptr %$weakPtr');
  e.line('%$newWeak = sub i32 %$weakVal, 1');
  e.line('store i32 %$newWeak, ptr %$weakPtr');
  e.line('%$isZero = icmp eq i32 %$newWeak, 0');
  e.terminate('br i1 %$isZero, label %$checkStrongLabel, label %$doneLabel');

  e.startBlock(checkStrongLabel);
  final strongVal = e.freshName('strongval');
  final strongIsZero = e.freshName('strongiszero');
  final freeSlotLabel = e.freshLabel('dropWeakFreeSlot');
  e.line('%$strongVal = load i32, ptr %$header');
  e.line('%$strongIsZero = icmp eq i32 %$strongVal, 0');
  e.terminate('br i1 %$strongIsZero, label %$freeSlotLabel, label %$doneLabel');

  e.startBlock(freeSlotLabel);
  _emitFreeSlotPushback(header, e);
  e.terminate('br label %$doneLabel');

  e.startBlock(doneLabel);
}

String _llvmType(DCType type, {required String context}) {
  if (type is DCInt) {
    switch (type.width) {
      case IntWidth.w8:
        return 'i8';
      case IntWidth.w16:
        return 'i16';
      case IntWidth.w32:
        return 'i32';
      case IntWidth.w64:
        return 'i64';
      case IntWidth.wSize:
        // M0/M1 target x86_64 only (m0-target.md §1) -- usize is 64 bits on
        // that target. A 32-bit target would need this to vary by
        // TargetMachine, same as the datalayout note in m0-target.md.
        return 'i64';
    }
  }
  if (type is DCVoid) return 'void';
  if (type is DCBool) return 'i1';
  // Opaque pointer type -- LLVM's only pointer representation since LLVM 15
  // (no `ptr.iN`-style element-typed pointers). Load/Store/IntToPtr above
  // carry the pointee type themselves (dest.type / value.type), so nothing
  // is lost by not encoding it in the pointer's own LLVM type.
  //
  if (type is DCPointer) return 'ptr';
  // DCHeapPointer (M2, ADR-0015): also plain opaque `ptr` at the LLVM-type
  // level -- the difference from DCPointer is entirely in which
  // instructions are legal on it (Alloc/Retain/Release vs. Load/Store/
  // IntToPtr) and in dcc-lower's insertion of retain/release at ownership
  // transfer points, not in the pointer's own LLVM representation. Both
  // ARC codegen (Alloc/Retain/Release, this file) and the insertion logic
  // (dcc-lower) now exist, so this no longer needs to throw defensively.
  if (type is DCHeapPointer) return 'ptr';
  // DCWeakPointer (M2, ADR-0023): same opaque `ptr` representation again
  // -- a weak pointer's numeric value IS a payload address (MakeWeak,
  // above), the type distinction exists only to keep MakeWeak/WeakLoad/
  // DropWeak from ever being handed a raw or strong pointer by mistake.
  if (type is DCWeakPointer) return 'ptr';
  // Anonymous/literal LLVM struct type -- fine for a by-value aggregate
  // (spec §5 Result<T,E>, docs/decisions/0014) constructed fresh via
  // MakeStruct; there is no name to preserve since DCStruct equality is
  // already structural (types.dart), matching LLVM's own literal-struct
  // identity rules.
  if (type is DCStruct) {
    final fieldTypes = type.fields.map((f) => _llvmType(f.type, context: context)).join(', ');
    return '{$fieldTypes}';
  }
  throw BackendError(
    '"$context": unsupported DCType $type (${type.runtimeType}) — backend '
    'emits DCInt/DCPointer/DCBool/DCStruct so far (see core/dc-ir/types.dart '
    'scope note; float/heap-object codegen is not implemented)',
  );
}

/// Accumulates one function's LLVM basic blocks. A single DC-IR instruction
/// (trapping arithmetic) can expand into several LLVM blocks; this class is
/// what makes that expansion mechanical instead of ad hoc string
/// concatenation. DC-IR's own single-block-per-M0/M1-function invariant is
/// unaffected -- this operates purely at LLVM-text-output granularity.
class _FunctionEmitter {
  final String context;
  final Set<String> declaredIntrinsics;
  final List<_Block> _finished = [];
  _Block? _current;
  int _counter = 0;

  _FunctionEmitter(this.context, this.declaredIntrinsics);

  String freshName(String prefix) => '$prefix${_counter++}';
  String freshLabel(String prefix) => '$prefix${_counter++}';

  void startBlock(String label) {
    if (_current != null) {
      throw BackendError(
        '"$context": started block "$label" while "${_current!.label}" has '
        'no terminator -- every arithmetic/emission path must call '
        'terminate() before startBlock()',
      );
    }
    _current = _Block(label);
  }

  void line(String text) {
    final block = _current;
    if (block == null) {
      throw BackendError('"$context": emitted an instruction with no open block');
    }
    block.lines.add(text);
  }

  void terminate(String text) {
    line(text);
    _finished.add(_current!);
    _current = null;
  }

  /// The real LLVM label of the block most recently finished via
  /// `terminate()` — used to find the TRUE final internal label of a DC-IR
  /// block's body (which may have called `startBlock` more than once
  /// internally, e.g. arithmetic overflow trapping), for real predecessor
  /// tracking. See `_collectPredecessors`'s doc comment.
  String get lastFinishedLabel {
    if (_finished.isEmpty) {
      throw BackendError('"$context": no block has been finished yet');
    }
    return _finished.last.label;
  }

  /// Inserts `lines` at the very TOP of the already-finished block named
  /// `label` — used to place `phi` instructions after real emission has
  /// determined every real predecessor label (LLVM requires `phi`s to
  /// precede every other instruction in their block).
  void prependToLabel(String label, List<String> lines) {
    if (lines.isEmpty) return;
    final block = _finished.firstWhere(
      (b) => b.label == label,
      orElse: () => throw BackendError('"$context": no finished block named "$label" to prepend phi lines to'),
    );
    block.lines.insertAll(0, lines);
  }

  String render() {
    if (_current != null) {
      throw BackendError(
        '"$context": function ended with block "${_current!.label}" '
        'unterminated -- every DC-IR block must end in a terminator '
        '(Return here; Branch/CondBranch are not implemented)',
      );
    }
    final buffer = StringBuffer();
    for (final block in _finished) {
      buffer.writeln('${block.label}:');
      for (final line in block.lines) {
        buffer.writeln('  $line');
      }
    }
    return buffer.toString();
  }
}

class _Block {
  final String label;
  final List<String> lines = [];
  _Block(this.label);
}

class BackendError extends Error {
  final String message;
  BackendError(this.message);

  @override
  String toString() => 'BackendError: $message';
}
