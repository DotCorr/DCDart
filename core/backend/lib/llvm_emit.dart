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
String emitModule(DCModule module, {String? targetTriple = 'x86_64-unknown-none-elf'}) {
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
  for (final fnText in functionBuffers) {
    buffer.write(fnText);
    buffer.writeln();
  }
  buffer.writeln('attributes #0 = { nounwind }');
  return buffer.toString();
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
      e.line('%v${instruction.dest.id.index} = load $type, ptr %v${instruction.pointer.id.index}');
    case Store():
      final type = _llvmType(instruction.value.type, context: context);
      e.line('store $type %v${instruction.value.id.index}, ptr %v${instruction.pointer.id.index}');
    case PortOut():
      // AT&T `outb %al, %dx` -- verified against a real disassembly (not
      // guessed) before wiring this in: value into {al} ($0), port into
      // {dx} ($1), matching the asm string's operand order exactly.
      e.line(
        'call void asm sideeffect "outb \$0, \$1", "{al},{dx}"'
        '(i8 %v${instruction.value.id.index}, i16 %v${instruction.port.id.index})',
      );
    case PortIn():
      // AT&T `inb %dx, %al` -- one output ({al}, numbered $0 per LLVM's
      // "outputs numbered first" rule) and one input ({dx}, $1), so the
      // asm string reads "inb $1, $0" to put the source (port) first and
      // the destination (result) second, matching real AT&T syntax.
      e.line(
        '%v${instruction.dest.id.index} = call i8 asm sideeffect "inb \$1, \$0", "={al},{dx}"'
        '(i16 %v${instruction.port.id.index})',
      );
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
  final header = e.freshName('hdr');
  final strong = e.freshName('strong');
  final newStrong = e.freshName('newstrong');
  e.line('%$header = getelementptr i8, ptr %v${instruction.object.id.index}, i64 -$_headerSizeBytes');
  e.line('%$strong = load i32, ptr %$header');
  e.line('%$newStrong = add i32 %$strong, 1');
  e.line('store i32 %$newStrong, ptr %$header');
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
