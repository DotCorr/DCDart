// core/dcc-lower/lib/lower.dart
//
// Kernel IR -> DC-IR lowering (DCDART_SPEC.md §1). Recognizes exactly the
// shapes verified empirically in docs/decisions/0008-m0-frontend-strategy.md
// (M0: `@bare u64 add(u64,u64) => a + b;`), 0010-pointer-load-store.md (M1:
// `Pointer<u32>.fromAddress`/`.value`), 0011-packed-struct-layout.md (M1:
// `@packed class ... extends Struct`), and 0014-result-value-representation.md
// (M1: `Result`/`.propagate()`, `if`). Everything is matched by exact Kernel
// IR node shape AND by the prelude library's URI, so an unrelated
// user-defined type/member elsewhere can never be misread as DCDart syntax.
//
// SCOPE CUT, on purpose (same discipline as core/dc-ir/instructions.dart):
// exactly the statement/expression shapes below and nothing else. Extend
// this file when a real conformance target needs more, not speculatively.
// Anything unrecognized throws DccLowerError naming the exact node type it
// choked on.
//
// `if`/`Result`/`.propagate()` (ADR-0014): fully implemented and verified
// end to end under WSL/Ubuntu (docs/known-gaps.md GAP-0007, resolved).
//
// M2 (ADR-0015/0016): `Alloc`/`Retain`/`Release` for real heap-allocated
// `HeapObject` subclasses -- real stored fields (not the getter-pair
// pattern below), real constructors, naive (non-elided) release-on-scope-
// exit. See docs/decisions/0016-heap-object-field-access.md.
//
// Struct field access (the OLDER, ADR-0011 pattern, unrelated to
// HeapObject/Alloc above) reuses ConstInt/IAdd/IntToPtr/Load/Store instead
// of a struct-specific instruction: a `@packed` struct "instance" is
// represented in DC-IR as nothing more than its base address (a plain
// DCInt.u64 value); `h.a` lowers to "address + offset -> pointer -> load".
// HeapObject fields use the newer PtrOffset instruction instead (ADR-0016)
// since their base is a DCHeapPointer, not a raw address.

import 'package:dc_elide/elide.dart';
import 'package:dc_ir/dc_ir.dart';
import 'package:kernel/kernel.dart';

import 'kernel_frontend.dart';

/// The DC-IR type for `Result` (ADR-0014): a by-value `{tag, payload}`
/// struct, tag 0 = Ok, 1 = Err. Only one concrete instantiation exists (see
/// prelude.dart) so this is a fixed constant, not derived per call site.
const DCStruct resultStructType = DCStruct('Result', [
  DCStructField('tag', DCInt.u64),
  DCStructField('payload', DCInt.u64),
]);

/// Lowers the DCDart source at [dartSourcePath] to a [DCModule].
///
/// [preludeUri] identifies core/runtime/dc-core-bare/prelude.dart — see this
/// file's header for why matching happens by URI, not name alone.
Future<DCModule> lowerToDCModule(
  String dartSourcePath, {
  required Uri preludeUri,
}) async {
  final compileResult = await compileToKernel(dartSourcePath);
  try {
    final component = loadComponentFromBinary(compileResult.dillPath);
    final targetLibrary = component.libraries.firstWhere(
      (lib) => lib.importUri == compileResult.sourceUri,
      orElse: () => throw DccLowerError(
        'lowered Kernel IR has no library matching $dartSourcePath '
        '(looked for ${compileResult.sourceUri})',
      ),
    );

    final structLayouts = _StructLayouts(preludeUri);
    final heapLayouts = _HeapLayouts(preludeUri);
    final functions = <DCFunction>[];
    for (final proc in targetLibrary.procedures) {
      if (!_hasMarkerAnnotation(proc.annotations, '_Bare', preludeUri)) continue;
      functions.add(_BareFunctionLowerer(proc, preludeUri, structLayouts, heapLayouts).lower());
    }

    if (functions.isEmpty) {
      throw DccLowerError('no @bare top-level function found in $dartSourcePath');
    }

    // (ADR-0022) Synthesize one destructor DCFunction per HeapObject
    // subclass that actually has a heap-typed field -- these are never
    // written by the user, only referenced by name (from Alloc's cls
    // header write) and called indirectly (from Release's codegen).
    for (final cls in targetLibrary.classes) {
      if (!heapLayouts.extendsHeapObject(cls)) continue;
      final destructorName = heapLayouts.destructorNameFor(cls);
      if (destructorName == null) continue; // no heap-typed fields, nothing to release
      functions.add(_buildDestructor(destructorName, heapLayouts.layoutFor(cls)));
    }

    // (ADR-0025) Redundant-pair removal, applied to every function --
    // user-lowered and synthesized destructors alike. Real M2 exit-
    // criterion scope (ROADMAP.md), not M3-only, per docs/known-gaps.md
    // GAP-0017 item 2's correction.
    final elidedFunctions = functions.map(elideRedundantRetainReleasePairs).toList();

    return DCModule(name: dartSourcePath, functions: elidedFunctions);
  } finally {
    compileResult.dispose();
  }
}

/// Builds one destructor `DCFunction` (ADR-0022): takes the dying object's
/// own payload pointer as its single parameter, releases each of its
/// heap-typed fields in turn (`PtrOffset`+`Load`+`Release` — the same
/// sequence `_lowerHeapFieldLoad` uses for a normal field read, followed by
/// releasing what was read), then returns void. Not tied to any one
/// `Procedure` or `_BareFunctionLowerer` instance — this body is entirely
/// synthesized, never sourced from user Dart code, and needs none of
/// `_BareFunctionLowerer`'s statement/expression-lowering machinery (no
/// control flow, no user-written logic, just a straight-line release
/// sequence).
///
/// Cascading to a field's OWN destructor (if its class also has one) needs
/// NO extra logic here: releasing a field just emits a plain `Release`,
/// and `Release`'s uniform backend codegen (docs/decisions/0022) already
/// checks that field object's own `cls` header at runtime, set correctly
/// back when that field object was itself `Alloc`'d. Depth is handled by
/// composition, not by this function walking the class graph recursively.
DCFunction _buildDestructor(String linkName, List<_StructField> fields) {
  var nextValueIndex = 0;
  ValueId allocId() => ValueId(nextValueIndex++);

  final selfValue = DCValue(allocId(), const DCHeapPointer(DCVoid()));
  final instructions = <DCInstruction>[];
  for (final field in fields) {
    if (field.heapFieldClass == null) continue; // scalar field -- nothing to release
    final fieldPtr = DCValue(allocId(), DCPointer(field.type));
    instructions.add(PtrOffset(dest: fieldPtr, base: selfValue, offsetBytes: field.offset));
    final fieldValue = DCValue(allocId(), field.type);
    instructions.add(Load(dest: fieldValue, pointer: fieldPtr));
    instructions.add(Release(object: fieldValue));
  }
  instructions.add(const Return());

  return DCFunction(
    linkName: linkName,
    paramTypes: [const DCHeapPointer(DCVoid())],
    returnType: const DCVoid(),
    mode: DCMode.bare,
    blocks: [DCBasicBlock(id: BlockId(0), params: [selfValue], body: instructions)],
  );
}

bool _hasMarkerAnnotation(List<Expression> annotations, String className, Uri preludeUri) {
  for (final ann in annotations) {
    if (ann is! ConstantExpression) continue;
    final constant = ann.constant;
    if (constant is! InstanceConstant) continue;
    if (constant.classNode.name != className) continue;
    if (constant.classNode.enclosingLibrary.importUri != preludeUri) continue;
    return true;
  }
  return false;
}

/// Safely checks whether [cls] transitively extends a prelude marker class
/// named [markerName] declared in [preludeUri], by walking the supertype
/// chain. Stops (returns false) the moment the chain reaches a reference
/// dcc-lower can't resolve — verified empirically: this happens for
/// ordinary platform classes like `Object` under `--no-link-platform`
/// (every user class implicitly extends `Object`, and `dart:core::Object`
/// is unbound with that flag; kernel_frontend.dart). An unresolvable
/// ancestor can never be one of DCDart's own prelude markers, so treating
/// it as "chain ends here" is correct, not a workaround for a real
/// ambiguity. This bug was latent in `extendsStruct` since M1 (ADR-0011) —
/// never triggered because every prior caller matched within one hop —
/// until `extendsHeapObject` (M2) hit it via a class whose hierarchy
/// doesn't match and walks past its marker into `Object`.
bool _extendsPreludeMarker(Class cls, String markerName, Uri preludeUri) {
  var supertype = cls.supertype;
  while (supertype != null) {
    final Class node;
    try {
      node = supertype.classNode;
    } catch (_) {
      return false;
    }
    if (node.name == markerName && node.enclosingLibrary.importUri == preludeUri) {
      return true;
    }
    supertype = node.supertype;
  }
  return false;
}

/// One `@packed` struct field: its name (for lookup), lowered [DCType], and
/// byte offset from the struct's base address (packed layout — sequential,
/// no natural-alignment padding).
///
/// `heapFieldClass` (ADR-0020, extended by ADR-0022): non-null iff `type`
/// is `DCHeapPointer` -- the CONCRETE class this field points to, which
/// `type` alone can't say (it's always the same `DCHeapPointer(DCVoid())`
/// placeholder, GAP-0003). Needed for destructor-cascade resolution
/// (`_HeapLayouts.destructorNameFor`) -- always `null` for `_StructField`s
/// built by `_StructLayouts` (`@packed` fields are never heap-typed).
class _StructField {
  final String name;
  final DCType type;
  final int offset;
  final Class? heapFieldClass;
  const _StructField(this.name, this.type, this.offset, {this.heapFieldClass});
}

/// Computes and caches `@packed` field layouts for `extends Struct`
/// subclasses. One instance shared across all functions in a module (layout
/// is a property of the class, not of any one function lowering it). This
/// is the ADR-0011 pointer-backed pattern -- unrelated to `Result`'s
/// by-value `resultStructType` above, despite both being "struct-shaped".
class _StructLayouts {
  final Uri preludeUri;
  final Map<Class, List<_StructField>> _cache = {};

  _StructLayouts(this.preludeUri);

  /// True if [cls] (transitively) extends the prelude's `Struct` marker
  /// class — checked by walking the supertype chain, so a struct extending
  /// another struct (not exercised by any conformance target yet, but not
  /// artificially forbidden either) would also match.
  bool extendsStruct(Class cls) => _extendsPreludeMarker(cls, 'Struct', preludeUri);

  List<_StructField> layoutFor(Class cls) {
    final cached = _cache[cls];
    if (cached != null) return cached;

    if (!_hasMarkerAnnotation(cls.annotations, '_Packed', preludeUri)) {
      throw DccLowerError(
        '"${cls.name}": extends Struct but has no @packed annotation — M1 '
        'only supports packed (no-padding) layout; natural-alignment '
        'layout is not implemented, see '
        'docs/decisions/0011-packed-struct-layout.md',
      );
    }

    final fields = <_StructField>[];
    var offset = 0;
    // Class.procedures preserves declaration order (verified empirically,
    // not assumed — see the ADR). Only getters define the field list;
    // matching setters are found by name when a field is written, not
    // counted separately, so a getter/setter pair is one field.
    for (final proc in cls.procedures) {
      if (proc.kind != ProcedureKind.Getter) continue;
      final type = _lowerFieldType(proc.function.returnType, preludeUri, cls.name, proc.name.text);
      fields.add(_StructField(proc.name.text, type, offset));
      offset += _byteWidth(type, cls.name, proc.name.text);
    }
    _cache[cls] = fields;
    return fields;
  }
}

/// Computes and caches field layouts for `extends HeapObject` subclasses
/// (ADR-0016). Same shape as `_StructLayouts` but reading real stored
/// `Class.fields` (declaration order) instead of getter/setter pairs —
/// heap objects don't need `@packed`'s pointer-backed-instance flexibility,
/// they're always reached through their own `Alloc`-returned
/// `DCHeapPointer`, so there's no reason to use the getter-pair
/// approximation here too.
class _HeapLayouts {
  final Uri preludeUri;
  final Map<Class, List<_StructField>> _cache = {};
  final Map<Class, String?> _destructorCache = {};

  _HeapLayouts(this.preludeUri);

  bool extendsHeapObject(Class cls) => _extendsPreludeMarker(cls, 'HeapObject', preludeUri);

  List<_StructField> layoutFor(Class cls) {
    final cached = _cache[cls];
    if (cached != null) return cached;

    final fields = <_StructField>[];
    var offset = 0;
    for (final field in cls.fields) {
      // heapLayouts: this -- ADR-0020. A HeapObject subclass's OWN field
      // can itself be HeapObject-typed (`class BoxHolder extends HeapObject
      // { final Box inner; ... }`); `@packed` struct fields (below,
      // `_StructLayouts.layoutFor` calls `_lowerFieldType` WITHOUT this
      // argument) never get this recognition -- a raw-memory `@packed`
      // struct has no ARC involvement at all, so a heap reference inside
      // one would be meaningless (nothing would ever retain/release it).
      final type = _lowerFieldType(field.type, preludeUri, cls.name, field.name.text, heapLayouts: this);
      Class? heapFieldClass;
      if (type is DCHeapPointer) {
        final fieldDartType = field.type;
        if (fieldDartType is InterfaceType) heapFieldClass = fieldDartType.classNode;
      }
      fields.add(_StructField(field.name.text, type, offset, heapFieldClass: heapFieldClass));
      offset += _byteWidth(type, cls.name, field.name.text);
    }
    _cache[cls] = fields;
    return fields;
  }

  /// The link name of [cls]'s destructor (ADR-0022), or `null` if [cls] has
  /// no heap-typed fields -- the overwhelmingly common case, and the only
  /// one that existed before this ADR (e.g. `Box`, whose only field is a
  /// `u64`). A destructor's own body releases each heap-typed field in
  /// turn (`_buildDestructor`); if one of THOSE fields' classes also has a
  /// destructor, that cascades automatically at runtime through `cls`
  /// (docs/decisions/0022) with no recursion needed here -- this method
  /// only decides whether THIS class needs a destructor at all, not what
  /// its transitive closure looks like.
  String? destructorNameFor(Class cls) {
    if (_destructorCache.containsKey(cls)) return _destructorCache[cls];
    final fields = layoutFor(cls);
    final hasHeapField = fields.any((f) => f.heapFieldClass != null);
    final name = hasHeapField ? '${cls.name}_dtor' : null;
    _destructorCache[cls] = name;
    return name;
  }

  int payloadSizeBytes(Class cls) {
    final fields = layoutFor(cls);
    if (fields.isEmpty) return 0;
    final last = fields.last;
    return last.offset + _byteWidth(last.type, cls.name, last.name);
  }
}

DCType _lowerFieldType(
  DartType type,
  Uri preludeUri,
  String className,
  String fieldName, {
  _HeapLayouts? heapLayouts,
}) {
  if (type is ExtensionType) {
    final decl = type.extensionTypeDeclaration;
    if (decl.enclosingLibrary.importUri == preludeUri) {
      switch (decl.name) {
        case 'u64':
          return DCInt.u64;
        case 'u32':
          return DCInt.u32;
        case 'u16':
          return DCInt.u16;
        case 'u8':
          return DCInt.u8;
      }
    }
  }
  // (M2, ADR-0020) A HeapObject-subclass field type, e.g. `final Box inner`
  // on another HeapObject subclass. Only offered to callers that pass a
  // `heapLayouts` (i.e. `_HeapLayouts.layoutFor` itself) -- see the call
  // site's comment for why `@packed`/`Struct` fields never get this.
  if (heapLayouts != null && type is InterfaceType) {
    // Safe to inspect .classNode: same reasoning as _lowerType's identical
    // check -- the referenced class is declared in this same component
    // (the source file being compiled), never an unbound platform
    // reference.
    final cls = type.classNode;
    if (heapLayouts.extendsHeapObject(cls)) {
      return const DCHeapPointer(DCVoid());
    }
  }
  throw DccLowerError(
    '"$className.$fieldName": unsupported struct field type $type '
    '(${type.runtimeType}) — only u8/u32/u64 fields, plus (for a '
    'HeapObject subclass\'s own fields) another HeapObject subclass, are '
    'handled',
  );
}

int _byteWidth(DCType type, String className, String fieldName) {
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
  // A DCHeapPointer field (ADR-0020) is a plain pointer at the storage
  // level, same width as every pointer this target uses (m0-target.md §1:
  // x86_64, 8-byte pointers) -- matches DCPointer's own implicit width
  // (opaque `ptr` in the backend, core/backend/lib/llvm_emit.dart).
  if (type is DCHeapPointer) return 8;
  throw DccLowerError('"$className.$fieldName": cannot compute byte width of $type');
}

/// One `@bare` function's lowering state. Params and locals share one
/// `VariableDeclaration -> DCValue` table. Unlike M0/M1's earlier single-
/// block design, this now builds real multi-block `DCFunction`s (needed for
/// `if`/`.propagate()`) via an explicit "one block open at a time" builder —
/// `_startBlock`/`_finishBlock`/`_addInstr`, mirroring core/backend's
/// `_FunctionEmitter` but at DC-IR-construction granularity instead of
/// LLVM-text granularity. `_blockOpen` tracks whether there's anywhere to
/// add the *next* instruction: false after a block-closing branch (e.g. an
/// if/else where both arms returned), which is exactly "no fallthrough" —
/// a subsequent statement in that state is genuinely unreachable code, and
/// `_addInstr` throws a specific error for it rather than silently
/// attaching instructions to a block that's already been finished.
class _BareFunctionLowerer {
  final Procedure proc;
  final Uri preludeUri;
  final _StructLayouts structLayouts;
  final _HeapLayouts heapLayouts;
  late final String context = proc.name.text;
  late final DCType _declaredReturnType;

  final Map<VariableDeclaration, DCValue> _values = {};
  final List<DCBasicBlock> _finishedBlocks = [];
  List<DCInstruction> _currentInstructions = [];
  List<DCValue> _currentBlockParams = const [];
  late BlockId _currentBlockId;
  bool _blockOpen = false;
  int _nextValueIndex = 0;
  int _nextBlockIndex = 0;

  // M2 naive (non-elided) release policy, ADR-0016/0017: every local
  // (VariableDeclaration, not DCValue) bound to a heap-typed value is
  // tracked here in declaration order; before lowering each `return`, every
  // tracked local NOT the one actually being returned gets a Release. No
  // escape analysis, no borrow inference -- just enough to be leak-free,
  // matching spec §3.2's own framing that naive ARC is slower than elided
  // ARC, not incorrect.
  //
  // Tracked by VariableDeclaration identity, NOT DCValue identity (ADR-0017)
  // -- aliasing (`final b2 = b;`) lowers to the exact same DCValue for both
  // `b` and `b2` (dc-ir has no copy instruction), so DCValue-keyed tracking
  // cannot tell them apart: it would push the same value twice with no
  // Retain (an undercount -- a real double-release) and "except" couldn't
  // distinguish "returning b" from "returning b2" either. Two distinct
  // VariableDeclarations can share one DCValue and still be released/
  // excepted independently, which is exactly what's needed.
  final List<VariableDeclaration> _heapLocals = [];

  // (ADR-0023) Same tracking scheme as _heapLocals, but for Weak<T>
  // locals, released via DropWeak instead of Release. A separate list --
  // not folded into _heapLocals -- since a Weak<T> value is DCWeakPointer-
  // typed, not DCHeapPointer, and needs the OPPOSITE instruction at scope
  // exit.
  final List<VariableDeclaration> _weakLocals = [];

  _BareFunctionLowerer(this.proc, this.preludeUri, this.structLayouts, this.heapLayouts);

  ValueId _allocId() => ValueId(_nextValueIndex++);
  BlockId _allocBlockId() => BlockId(_nextBlockIndex++);

  void _startBlock(BlockId id, List<DCValue> params) {
    if (_blockOpen) {
      throw DccLowerError(
        '"$context": internal error — started block ${id.index} while a '
        'block was already open (dcc-lower bug, not a source error)',
      );
    }
    _currentBlockId = id;
    _currentBlockParams = params;
    _currentInstructions = [];
    _blockOpen = true;
  }

  void _finishBlock() {
    if (!_blockOpen) {
      throw DccLowerError(
        '"$context": internal error — tried to finish a block that was not '
        'open (dcc-lower bug, not a source error)',
      );
    }
    _finishedBlocks.add(
      DCBasicBlock(id: _currentBlockId, params: _currentBlockParams, body: _currentInstructions),
    );
    _blockOpen = false;
  }

  void _addInstr(DCInstruction instr) {
    if (!_blockOpen) {
      throw DccLowerError(
        '"$context": statement appears after control flow that already '
        'returned on every path — unreachable code is not supported',
      );
    }
    _currentInstructions.add(instr);
  }

  DCFunction lower() {
    final fn = proc.function;

    final paramTypes = <DCType>[];
    final paramValues = <DCValue>[];
    for (final param in fn.positionalParameters) {
      final type = _lowerType(param.type, context: '$context param ${param.name}');
      final value = DCValue(_allocId(), type);
      _values[param] = value;
      paramTypes.add(type);
      paramValues.add(value);
      // (M2, ADR-0021) `@owned` (spec §3.2 item 2: "Only @owned params
      // transfer") -- every other HeapObject-typed parameter is borrowed
      // by default (ADR-0019) and never tracked. An `@owned` parameter IS
      // a `VariableDeclaration` (Kernel represents parameters that way),
      // so it reuses `_heapLocals`/`_releaseHeapLocals` exactly as any
      // local does -- no separate tracking structure needed. The caller
      // side (`_lowerBareCall`) is responsible for `Retain`-ing the
      // argument before the call so this function's own release doesn't
      // under-count a reference someone else is still holding.
      if (type is DCHeapPointer && _hasMarkerAnnotation(param.annotations, '_Owned', preludeUri)) {
        _heapLocals.add(param);
      }
      // (ADR-0023) Same convention extended to Weak<T> parameters: @owned
      // means this function is responsible for DropWeak-ing it before
      // returning.
      if (type is DCWeakPointer && _hasMarkerAnnotation(param.annotations, '_Owned', preludeUri)) {
        _weakLocals.add(param);
      }
    }

    // void is legal as a return type (a @bare procedure with no result)
    // but not as a param/pointee/field type, so it's handled here rather
    // than in the shared _lowerType.
    final returnType = fn.returnType is VoidType
        ? const DCVoid()
        : _lowerType(fn.returnType, context: '$context return type');
    _declaredReturnType = returnType;

    _startBlock(_allocBlockId(), paramValues);

    final body = fn.body;
    if (body is ReturnStatement) {
      _lowerReturn(body);
    } else if (body is Block) {
      for (final stmt in body.statements) {
        if (!_blockOpen) {
          throw DccLowerError(
            '"$context": unreachable statement after control flow that '
            'already returned on every path',
          );
        }
        _lowerStatement(stmt);
      }
    } else {
      throw DccLowerError(
        '"$context": body is ${body.runtimeType} — only a single return '
        'statement or a block of statements is handled',
      );
    }

    // A void function whose body falls off the end (no explicit `return;`)
    // needs an implicit void return. Only valid when returnType is void and
    // the last block is still open (if it already closed via if/else both
    // returning, there's nothing to add).
    if (_blockOpen) {
      final lastIsReturn = _currentInstructions.isNotEmpty && _currentInstructions.last is Return;
      if (!lastIsReturn) {
        if (returnType is! DCVoid) {
          throw DccLowerError(
            '"$context": body falls off the end without a return, but the '
            'return type is $returnType, not void — this should have been '
            'a front_end error',
          );
        }
        _addInstr(const Return());
      }
      _finishBlock();
    }

    return DCFunction(
      linkName: context,
      paramTypes: paramTypes,
      returnType: returnType,
      mode: DCMode.bare,
      blocks: _finishedBlocks,
    );
  }

  void _lowerStatement(Statement stmt) {
    if (stmt is VariableDeclaration) {
      final init = stmt.initializer;
      if (init == null) {
        throw DccLowerError(
          '"$context": local "${stmt.name}" has no initializer — every '
          'local must be initialized at declaration, M1 does not lower '
          'uninitialized locals',
        );
      }
      final value = _lowerExpression(init);
      _values[stmt] = value;
      if (value.type is DCHeapPointer) {
        // Retain unless the initializer is a known FRESH-OWNERSHIP source
        // -- one that already hands this local a strong reference nothing
        // else is entitled to release:
        //   - ConstructorInvocation: a HeapObject constructor, i.e. a fresh
        //     `Alloc` (strong=1 already, ADR-0016).
        //   - StaticInvocation: a call to another @bare function
        //     (ADR-0018) whose return type is DCHeapPointer -- ownership
        //     transfers to the caller unreleased, by the same convention
        //     ADR-0019 established for `return b;`.
        // Every other shape that can produce a DCHeapPointer value --
        // aliasing an existing local (`final b2 = b;`, a VariableGet,
        // ADR-0017) or reading a borrowed field off another heap object
        // (`final c = holder.inner;`, an InstanceGet, ADR-0020) -- exposes
        // a reference someone ELSE still owns, so binding it to a new
        // tracked local (which WILL emit its own Release below) needs its
        // own Retain first, or that shared reference gets over-released.
        if (!_isFreshHeapOwnership(init)) {
          _addInstr(Retain(object: value));
        }
        _heapLocals.add(stmt);
      }
      if (value.type is DCWeakPointer) {
        // (ADR-0023) Only fresh-ownership sources are handled: a direct
        // `Weak.fromStrong(...)` construction (MakeWeak already
        // incremented the weak count) or a call returning `Weak<T>`
        // (ownership transferred out, same convention as ADR-0019).
        // Aliasing an existing Weak<T> local (`final w2 = w1;`) would need
        // its own weak-count increment that nothing here performs yet --
        // rather than silently under-count and double-DropWeak (the exact
        // bug class ADR-0017 fixed for heap locals), this throws a clear
        // error instead of miscompiling.
        if (!_isFreshHeapOwnership(init)) {
          throw DccLowerError(
            '"$context": local "${stmt.name}" is Weak-typed but its '
            'initializer is not a fresh Weak.fromStrong(...) construction '
            'or a call returning Weak<T> ($init, ${init.runtimeType}) -- '
            'aliasing an existing Weak<T> local is not supported yet',
          );
        }
        _weakLocals.add(stmt);
      }
      return;
    }

    if (stmt is ExpressionStatement) {
      final expr = stmt.expression;
      if (expr is InstanceSet) {
        final target = expr.interfaceTarget;
        final enclosingClass = target.enclosingClass;

        if (_isPointerValueMember(target)) {
          final pointer = _lowerExpression(expr.receiver);
          final value = _lowerExpression(expr.value);
          _addInstr(Store(pointer: pointer, value: value));
          return;
        }

        if (enclosingClass != null && structLayouts.extendsStruct(enclosingClass)) {
          _lowerStructFieldStore(expr, enclosingClass);
          return;
        }
      }
      // (M2, ADR-0027) `x = <expr>;` -- reassigning an existing non-final
      // local. DC-IR is SSA (dc-ir/README.md): there is no single fixed
      // SSA value a "mutable variable" keeps across its lifetime.
      // Reassignment is just rebinding `_values[variable]` to point at a
      // freshly-lowered DCValue -- every SUBSEQUENT VariableGet naturally
      // sees the new one, since `_values` is consulted lazily. This is
      // safe for straight-line code and for a reassignment inside an
      // if-branch, because `_closeBranchIfOpen` already requires every
      // WRITTEN branch to terminate via `return` (GAP-0007) -- there is
      // no "conditionally reassign, then fall through with an ambiguous
      // merged value" shape reachable today (that's the classic SSA
      // phi/merge problem, and it stays out of scope until `_lowerIf`
      // itself supports merging control flow back together).
      //
      // Scalar (`DCInt`) ONLY. A heap- or weak-typed reassignment raises
      // real ownership questions this project has deliberately deferred
      // before (docs/known-gaps.md GAP-0017's move-semantics note): does
      // overwriting release the OLD value? Does capturing the new one
      // retain it? Getting this wrong is a leak or a use-after-free, not
      // a cosmetic bug -- so it throws a clear, honest error instead of
      // guessing at a policy nobody has designed yet.
      if (expr is VariableSet) {
        final variable = expr.variable;
        final oldValue = _values[variable];
        if (oldValue == null) {
          throw DccLowerError(
            '"$context": assignment to unrecognized variable "${variable.name}"',
          );
        }
        if (oldValue.type is! DCInt) {
          throw DccLowerError(
            '"$context": reassigning "${variable.name}" (type ${oldValue.type}) '
            'is not supported -- only scalar (u8/u32/u64) locals can be '
            'reassigned; heap- and weak-typed reassignment needs a real '
            'ownership policy this project has not designed yet, see '
            'docs/known-gaps.md',
          );
        }
        final newValue = _lowerExpression(expr.value);
        if (newValue.type != oldValue.type) {
          throw DccLowerError(
            '"$context": assigning a value of type ${newValue.type} to '
            '"${variable.name}", declared ${oldValue.type} -- no implicit '
            'widening (same rule as arithmetic)',
          );
        }
        _values[variable] = newValue;
        return;
      }
      // (Port I/O escalation, docs/decisions/0029-port-io.md) `Port.outb
      // (port, value);` as a bare statement -- the first void-returning
      // call this project has needed to lower as a statement rather than
      // an expression (dcc-lower/README.md already flagged this as
      // unimplemented, "no target has needed it" -- this is that target).
      if (expr is StaticInvocation) {
        final target = expr.target;
        if (target.isStatic &&
            target.enclosingClass?.name == 'Port' &&
            target.name.text == 'outb' &&
            target.enclosingLibrary.importUri == preludeUri) {
          final args = expr.arguments.positional;
          final port = _lowerExpression(args[0]);
          final value = _lowerExpression(args[1]);
          if (port.type != DCInt.u16) {
            throw DccLowerError(
              '"$context": Port.outb\'s port argument has type ${port.type}, '
              'expected u16',
            );
          }
          if (value.type != DCInt.u8) {
            throw DccLowerError(
              '"$context": Port.outb\'s value argument has type '
              '${value.type}, expected u8',
            );
          }
          _addInstr(PortOut(port: port, value: value));
          return;
        }
      }
      throw DccLowerError(
        '"$context": unsupported expression statement $expr '
        '(${expr.runtimeType}) — M1 only understands `pointer.value = x;`, '
        '`structInstance.field = x;`, scalar local reassignment '
        '(`x = <expr>;`), and `Port.outb(port, value);`',
      );
    }

    if (stmt is ReturnStatement) {
      _lowerReturn(stmt);
      return;
    }

    if (stmt is IfStatement) {
      _lowerIf(stmt);
      return;
    }

    if (stmt is WhileStatement) {
      _lowerWhile(stmt);
      return;
    }

    throw DccLowerError(
      '"$context": unsupported statement ${stmt.runtimeType} — see '
      'core/dcc-lower/README.md for exactly what is handled',
    );
  }

  /// `if (cond) { thenBranch } [else { elseBranch }]`. M1 scope: every
  /// branch that's written must terminate (end in `return`) — there is no
  /// merge-block/phi generation from source yet (docs/known-gaps.md
  /// GAP-0007). Two shapes are supported:
  ///   - if/else, both branches terminate: no fallthrough after the if:
  ///     subsequent statements (if any) are unreachable and throw.
  ///   - if without else, then-branch terminates: the false path IS the
  ///     fallthrough — becomes the new open "current" block that subsequent
  ///     statements continue into. This is the guard-clause pattern
  ///     `Result`-returning functions use with `.propagate()`.
  void _lowerIf(IfStatement stmt) {
    final cond = _lowerExpression(stmt.condition);
    if (cond.type is! DCBool) {
      throw DccLowerError(
        '"$context": if-condition has non-DCBool type ${cond.type} — '
        'dcc-lower bug, front_end should have required a real bool here',
      );
    }

    final thenBlockId = _allocBlockId();
    final elseBlockId = _allocBlockId();
    final otherwise = stmt.otherwise;

    _addInstr(
      CondBranch(cond: cond, trueTarget: thenBlockId, trueArgs: const [], falseTarget: elseBlockId, falseArgs: const []),
    );
    _finishBlock();

    // Heap/weak locals declared inside a branch are scoped to that branch:
    // once it closes (always via return -- _closeBranchIfOpen requires
    // it), their releases have already been emitted by _lowerReturn, so
    // they must NOT still be tracked for a return in a DIFFERENT branch to
    // see (that would double-release an already-freed slot). Snapshot and
    // truncate BOTH lists around each branch (ADR-0023 extended this to
    // _weakLocals, same reasoning as _heapLocals).
    //
    // `_values` gets the SAME snapshot/restore treatment (ADR-0027), for a
    // DIFFERENT but related reason: a scalar reassignment (`x = ...;`,
    // ADR-0027) REBINDS `_values[decl]` to a new DCValue defined INSIDE
    // whichever branch's blocks are currently open. Without restoring
    // `_values` after the branch closes, that rebinding would leak into
    // a sibling branch or the fallthrough continuation, which reference a
    // DCValue that doesn't dominate their own blocks -- a real, verified
    // bug (a genuine LLVM "does not dominate all uses" failure caught
    // building this very feature, not a hypothetical). A `VariableDeclaration`
    // made INSIDE a branch is correctly discarded by the same restore,
    // matching ordinary lexical block-scoping -- it was never visible
    // outside the branch at the Dart source level either.
    _startBlock(thenBlockId, const []);
    final heapLocalsBeforeThen = _heapLocals.length;
    final weakLocalsBeforeThen = _weakLocals.length;
    final valuesBeforeThen = Map<VariableDeclaration, DCValue>.from(_values);
    _lowerBranchBody(stmt.then);
    _closeBranchIfOpen('then');
    _heapLocals.removeRange(heapLocalsBeforeThen, _heapLocals.length);
    _weakLocals.removeRange(weakLocalsBeforeThen, _weakLocals.length);
    _values
      ..clear()
      ..addAll(valuesBeforeThen);

    _startBlock(elseBlockId, const []);
    if (otherwise != null) {
      final heapLocalsBeforeElse = _heapLocals.length;
      final weakLocalsBeforeElse = _weakLocals.length;
      final valuesBeforeElse = Map<VariableDeclaration, DCValue>.from(_values);
      _lowerBranchBody(otherwise);
      _closeBranchIfOpen('else');
      _heapLocals.removeRange(heapLocalsBeforeElse, _heapLocals.length);
      _weakLocals.removeRange(weakLocalsBeforeElse, _weakLocals.length);
      _values
        ..clear()
        ..addAll(valuesBeforeElse);
      // Both arms closed (or this is unreachable if they didn't -- caught
      // above): nothing left open. A subsequent statement at this point is
      // genuinely unreachable; the caller's loop / _addInstr catches it.
    }
    // else: no `otherwise` -- elseBlockId IS the fallthrough continuation,
    // deliberately left open for subsequent statements to continue into,
    // correctly seeing `_values` as restored to its pre-then-branch state
    // (the then-branch's own reassignments/declarations are scoped to
    // itself, exactly like the heap/weak-local lists above).
  }

  void _lowerBranchBody(Statement stmt) {
    if (stmt is Block) {
      for (final s in stmt.statements) {
        if (!_blockOpen) {
          throw DccLowerError(
            '"$context": unreachable statement after control flow that '
            'already returned on every path',
          );
        }
        _lowerStatement(s);
      }
    } else {
      _lowerStatement(stmt);
    }
  }

  void _closeBranchIfOpen(String branchName) {
    if (!_blockOpen) return; // branch already closed itself (nested if, etc.)
    final last = _currentInstructions.isNotEmpty ? _currentInstructions.last : null;
    if (last is! DCTerminator) {
      throw DccLowerError(
        '"$context": if-branch ($branchName) does not end in a return — M1 '
        'requires every written if-branch to terminate; merging control '
        'flow back together from source is not implemented, see '
        'docs/known-gaps.md GAP-0007',
      );
    }
    _finishBlock();
  }

  /// `while (cond) { body }` (M2, ADR-0028). DC-IR already represents merge
  /// points via block PARAMETERS (ssa.dart's own design, no separate phi
  /// instruction) — a loop header is just an ordinary block with two
  /// predecessors (the pre-loop entry edge and the body's back edge), which
  /// `core/backend`'s `_emitPhiNodes` already handles generically (it scans
  /// EVERY predecessor of every block in the whole function via
  /// `_collectPredecessors`, not just `if`/`else` merges — confirmed by
  /// reading it, not assumed). So the real work here is entirely
  /// dcc-lower's: figure out which locals are "loop-carried" (reassigned
  /// somewhere in the body) and thread them through the header block's
  /// params, mirroring how a function's own parameters are just
  /// `blocks[0].params` (function.dart's own doc comment).
  ///
  /// SCOPE CUT, on purpose, matching this project's whole-session discipline
  /// of building exactly what a real conformance target needs, not
  /// speculatively:
  ///   - `while` only, not `for`/`do-while` (different Kernel AST shapes,
  ///     no target needs them yet).
  ///   - No `break`/`continue` (no BreakStatement lowering exists).
  ///   - No nested loops — `_collectLoopCarriedCandidates` throws explicitly
  ///     rather than silently scoping the carried-variable analysis to the
  ///     wrong loop.
  ///   - No heap- or weak-typed local may be declared anywhere in the loop
  ///     body. The naive release policy (ADR-0016/0017) releases tracked
  ///     locals before each `return` — a loop's back edge is NOT a
  ///     `return`, so nothing would ever release a heap local declared
  ///     inside the body on any iteration that isn't the function's last.
  ///     Getting this right needs real design (release before the back
  ///     edge? every iteration? what about a heap local escaping via a
  ///     loop-carried reassignment, which isn't even supported for scalars
  ///     let alone heap types?) that hasn't happened yet — see
  ///     docs/known-gaps.md. Enforced by checking `_heapLocals`/
  ///     `_weakLocals` didn't grow across the body, rather than guessing a
  ///     policy no one has decided.
  void _lowerWhile(WhileStatement stmt) {
    final candidates = <VariableDeclaration>{};
    _collectLoopCarriedCandidates(stmt.body, candidates);

    // Only variables already tracked BEFORE the loop starts are genuinely
    // "carried" across iterations — a variable declared (and possibly
    // reassigned) fresh inside the body every iteration isn't in `_values`
    // yet at this point, so it's naturally excluded here rather than
    // needing a separate "declared inside vs outside the loop" AST check.
    final loopVars = <VariableDeclaration>[
      for (final v in candidates)
        if (_values.containsKey(v)) v,
    ];
    for (final v in loopVars) {
      final current = _values[v]!;
      if (current.type is! DCInt) {
        throw DccLowerError(
          '"$context": loop-carried variable "${v.name}" has type '
          '${current.type} — only scalar (u8/u32/u64) locals can be '
          'reassigned inside a loop body, same rule as ADR-0027\'s '
          'straight-line reassignment',
        );
      }
    }

    final condBlockId = _allocBlockId();
    final bodyBlockId = _allocBlockId();
    final exitBlockId = _allocBlockId();

    final entryArgs = [for (final v in loopVars) _values[v]!];
    _addInstr(Branch(target: condBlockId, args: entryArgs));
    _finishBlock();

    final condParams = [
      for (final v in loopVars) DCValue(_allocId(), _values[v]!.type),
    ];
    _startBlock(condBlockId, condParams);
    for (var i = 0; i < loopVars.length; i++) {
      _values[loopVars[i]] = condParams[i];
    }
    final cond = _lowerExpression(stmt.condition);
    if (cond.type is! DCBool) {
      throw DccLowerError(
        '"$context": while-condition has non-DCBool type ${cond.type} — '
        'dcc-lower bug, front_end should have required a real bool here',
      );
    }
    _addInstr(
      CondBranch(cond: cond, trueTarget: bodyBlockId, trueArgs: const [], falseTarget: exitBlockId, falseArgs: const []),
    );
    _finishBlock();

    _startBlock(bodyBlockId, const []);
    final heapLocalsBeforeBody = _heapLocals.length;
    final weakLocalsBeforeBody = _weakLocals.length;
    _lowerBranchBody(stmt.body);
    if (_heapLocals.length != heapLocalsBeforeBody || _weakLocals.length != weakLocalsBeforeBody) {
      throw DccLowerError(
        '"$context": a heap- or weak-typed local was declared inside a '
        'while-loop body — not supported yet, see docs/known-gaps.md '
        '(naive ARC has no release policy for a loop back edge yet)',
      );
    }
    // Only wire the back edge if some path through the body still falls
    // through (_blockOpen) — a body where every path returns has no
    // reachable back edge at all, which is a legal (if degenerate) program:
    // the loop's condition is checked once, and if the body is entered it
    // always returns before completing a second iteration.
    if (_blockOpen) {
      final backArgs = [for (final v in loopVars) _values[v]!];
      _addInstr(Branch(target: condBlockId, args: backArgs));
      _finishBlock();
    }

    // What's live at the exit block is the header's OWN phi params — not
    // whatever the body last computed, which does not dominate the exit
    // (the exit is only reachable via the header's false edge, never
    // through the body). Same restore-after-branch reasoning as
    // `_lowerIf`'s `_values` handling (ADR-0027), specialized to a loop
    // header instead of an if/else merge.
    for (var i = 0; i < loopVars.length; i++) {
      _values[loopVars[i]] = condParams[i];
    }
    _startBlock(exitBlockId, const []);
  }

  /// Pure Kernel-IR-AST walk collecting every `VariableSet` target
  /// reachable inside `stmt` (recursing into `Block` and `IfStatement`'s
  /// arms) — used by `_lowerWhile` to find candidate loop-carried variables
  /// BEFORE actually lowering the body (the header block's phi params must
  /// exist before the body that reads/writes them does). Throws on a
  /// nested loop rather than silently scoping the analysis to the wrong
  /// loop — nested loops are real, separate, unimplemented work.
  void _collectLoopCarriedCandidates(Statement stmt, Set<VariableDeclaration> out) {
    if (stmt is Block) {
      for (final s in stmt.statements) {
        _collectLoopCarriedCandidates(s, out);
      }
      return;
    }
    if (stmt is ExpressionStatement && stmt.expression is VariableSet) {
      out.add((stmt.expression as VariableSet).variable);
      return;
    }
    if (stmt is IfStatement) {
      _collectLoopCarriedCandidates(stmt.then, out);
      final otherwise = stmt.otherwise;
      if (otherwise != null) {
        _collectLoopCarriedCandidates(otherwise, out);
      }
      return;
    }
    if (stmt is WhileStatement) {
      throw DccLowerError('"$context": nested while-loops are not supported yet');
    }
    // Anything else (VariableDeclaration, ReturnStatement, a non-VariableSet
    // ExpressionStatement) can't itself carry a VariableSet target this
    // project's lowering recognizes — ignored, not an error, since
    // `_lowerBranchBody` will report a real problem with it on its own if
    // it's genuinely unsupported.
  }

  void _lowerReturn(ReturnStatement stmt) {
    final expr = stmt.expression;
    if (expr == null) {
      _releaseHeapLocals(exceptDecl: null);
      _releaseWeakLocals(exceptDecl: null);
      _addInstr(const Return());
      return;
    }
    final value = _lowerExpression(expr);
    // Release every tracked heap/weak local except the one actually being
    // returned -- ownership of THAT specific local's reference transfers to
    // the caller, not released here. Excepted by VariableDeclaration
    // identity, NOT DCValue identity (ADR-0017): when `expr` is a bare
    // `VariableGet`, its `.variable` names exactly which declaration is
    // being returned, even if an alias (`final b2 = b; return b2;`) shares
    // its DCValue with another still-tracked local (`b`) that must still be
    // released. A non-VariableGet return expression (e.g. a field read, or
    // a freshly constructed-and-immediately-returned heap object that was
    // never bound to a local) excepts nothing -- there's no tracked local
    // to protect from release. The SAME exceptDecl works for both lists --
    // a VariableDeclaration is only ever tracked in one of them (a local is
    // either DCHeapPointer- or DCWeakPointer-typed, never both), so
    // identity comparison against either list is safe with no extra check.
    final exceptDecl = expr is VariableGet ? expr.variable : null;
    _releaseHeapLocals(exceptDecl: exceptDecl);
    _releaseWeakLocals(exceptDecl: exceptDecl);
    _addInstr(Return(value: value));
  }

  void _releaseHeapLocals({required VariableDeclaration? exceptDecl}) {
    for (final decl in _heapLocals) {
      if (decl == exceptDecl) continue;
      _addInstr(Release(object: _values[decl]!));
    }
  }

  /// (ADR-0023) `DropWeak` counterpart to `_releaseHeapLocals`, for every
  /// tracked `Weak<T>` local -- same except-by-declaration logic.
  void _releaseWeakLocals({required VariableDeclaration? exceptDecl}) {
    for (final decl in _weakLocals) {
      if (decl == exceptDecl) continue;
      _addInstr(DropWeak(object: _values[decl]!));
    }
  }

  /// True if `expr` is a known FRESH-OWNERSHIP source for a `DCHeapPointer`
  /// value -- one that already hands the receiver a strong reference
  /// nothing else is entitled to release:
  ///   - `ConstructorInvocation`: a `HeapObject` constructor, i.e. a fresh
  ///     `Alloc` (strong=1 already, ADR-0016).
  ///   - `StaticInvocation`: a call to another `@bare` function (ADR-0018)
  ///     whose return type is `DCHeapPointer` -- ownership transfers to
  ///     the caller unreleased, by the convention ADR-0019 established.
  ///   - `InstanceGet` on `Weak<T>.value` (ADR-0023): `WeakLoad`'s own
  ///     codegen already retains when the target is alive (and never
  ///     retains a null pointer, since it checks liveness first) -- this
  ///     is a genuine fresh-owned reference (or null), the same contract
  ///     as the other two shapes, NOT a borrowed field read like every
  ///     other `InstanceGet` this project recognizes.
  /// Every OTHER shape that can produce a `DCHeapPointer` value --
  /// aliasing an existing local (`VariableGet`, ADR-0017), a borrowed
  /// HeapObject field read (`InstanceGet`, ADR-0020), or a value being
  /// handed to an `@owned` parameter (ADR-0021) -- exposes a reference
  /// someone ELSE still owns, and needs its own `Retain` wherever it's
  /// captured by something that will independently release it. One shared
  /// check for every call site that needs this distinction, rather than
  /// re-deriving it per site as each was discovered.
  bool _isFreshHeapOwnership(Expression expr) {
    if (expr is ConstructorInvocation || expr is StaticInvocation) return true;
    if (expr is InstanceGet) {
      final target = expr.interfaceTarget;
      return target.name.text == 'value' &&
          target.enclosingClass?.name == 'Weak' &&
          target.enclosingLibrary.importUri == preludeUri;
    }
    return false;
  }

  DCValue _lowerExpression(Expression expr) {
    if (expr is VariableGet) {
      final value = _values[expr.variable];
      if (value == null) {
        throw DccLowerError(
          '"$context": reference to unrecognized variable "${expr.variable.name}"',
        );
      }
      return value;
    }

    if (expr is StaticInvocation) {
      final target = expr.target;

      if (target.isExtensionTypeMember &&
          target.name.text == 'u64|+' &&
          target.enclosingLibrary.importUri == preludeUri) {
        return _lowerU64Binary(expr, (dest, lhs, rhs) {
          _addInstr(IAdd(dest: dest, lhs: lhs, rhs: rhs, overflow: Overflow.trapping));
        }, DCInt.u64);
      }

      if (target.isExtensionTypeMember &&
          target.name.text == 'u64|<' &&
          target.enclosingLibrary.importUri == preludeUri) {
        // DCBool assigned directly, same as u64|+ assigns DCInt.u64 directly
        // -- never consult front_end's inferred (real, unbound-under
        // --no-link-platform) `bool` type. See ADR-0014.
        return _lowerU64Binary(expr, (dest, lhs, rhs) {
          _addInstr(ICmp(dest: dest, predicate: ICmpPredicate.ult, lhs: lhs, rhs: rhs));
        }, const DCBool());
      }

      if (target.isExtensionTypeMember &&
          target.name.text == 'u64|-' &&
          target.enclosingLibrary.importUri == preludeUri) {
        // (M2, ADR-0026) ISub already existed and had real backend codegen
        // since M0 -- only the source-level `-` operator and this
        // recognition were missing.
        return _lowerU64Binary(expr, (dest, lhs, rhs) {
          _addInstr(ISub(dest: dest, lhs: lhs, rhs: rhs, overflow: Overflow.trapping));
        }, DCInt.u64);
      }

      // Bitwise ops (`&`/`|`/`^`/`<<`/`>>`) for u8/u16/u32/u64 -- added for
      // oscortex_core's interrupts milestone (IDT/PIC/UART register
      // manipulation). One generalized check rather than 20 near-identical
      // blocks (4 widths x 5 ops): `target.name.text` follows the same
      // "<width>|<op>" shape the u64|+/u64|</u64|- checks above already
      // rely on, so this parses the width and op out of it and dispatches
      // through a lookup -- same generalization the sized-int-literal
      // check below already applied to u64(...)/u8(...)/u16(...)/u32(...).
      // Uses `indexOf`/`substring` on the FIRST `|`, not `String.split`:
      // the OR operator's own name IS the character `|`, so
      // `"u64|｜".split('|')` would wrongly produce three empty-ish
      // parts instead of `["u64", "|"]`.
      if (target.isExtensionTypeMember && target.enclosingLibrary.importUri == preludeUri) {
        final sep = target.name.text.indexOf('|');
        if (sep > 0) {
          final widthType = switch (target.name.text.substring(0, sep)) {
            'u8' => DCInt.u8,
            'u16' => DCInt.u16,
            'u32' => DCInt.u32,
            'u64' => DCInt.u64,
            _ => null,
          };
          final op = target.name.text.substring(sep + 1);
          final emit = switch (op) {
            '&' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IAnd(dest: dest, lhs: lhs, rhs: rhs)),
            '|' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IOr(dest: dest, lhs: lhs, rhs: rhs)),
            '^' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IXor(dest: dest, lhs: lhs, rhs: rhs)),
            '<<' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IShl(dest: dest, lhs: lhs, rhs: rhs)),
            '>>' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IShr(dest: dest, lhs: lhs, rhs: rhs)),
            _ => null,
          };
          if (widthType != null && emit != null) {
            return _lowerU64Binary(expr, emit, widthType);
          }
        }
      }

      if (target.isFactory &&
          target.enclosingClass?.name == 'Result' &&
          target.enclosingLibrary.importUri == preludeUri) {
        return _lowerResultFactory(expr, target.name.text);
      }

      // `u64(1)`/`u32(1)`/`u16(1)`/`u8(1)` -- constructing a sized-int
      // literal. Synthesized by front_end as a StaticInvocation of the
      // extension type's implicit constructor (verified empirically for
      // u64: target.name.text == "u64|constructor#"; the other three
      // widths follow the identical "<width>|constructor#" shape). Only
      // literal arguments are handled -- `u64(someRuntimeInt)` would need a
      // real int-to-sized-int conversion instruction this project hasn't
      // needed yet (DCDart's real design has no implicit int/sized-int
      // conversion anyway, spec §4.1: "No implicit widening or narrowing").
      // (Port I/O escalation, docs/decisions/0029-port-io.md, is what
      // first needed u8/u16/u32 literals -- u64 was the only width with
      // this recognized until now, since nothing else had constructed a
      // narrower literal from source.)
      if (target.isExtensionTypeMember && target.enclosingLibrary.importUri == preludeUri) {
        final sizedIntType = switch (target.name.text) {
          'u8|constructor#' => DCInt.u8,
          'u16|constructor#' => DCInt.u16,
          'u32|constructor#' => DCInt.u32,
          'u64|constructor#' => DCInt.u64,
          _ => null,
        };
        if (sizedIntType != null) {
          final arg = expr.arguments.positional.single;
          if (arg is! IntLiteral) {
            throw DccLowerError(
              '"$context": a $sizedIntType literal constructed from a '
              'non-literal expression $arg (${arg.runtimeType}) — only '
              'integer-literal arguments are handled',
            );
          }
          final dest = DCValue(_allocId(), sizedIntType);
          _addInstr(ConstInt(dest: dest, bits: arg.value));
          return dest;
        }
      }

      // (Port I/O escalation, docs/decisions/0029-port-io.md) `Port.inb
      // (port)` -- a plain static method call (not an extension-type
      // member, not a factory constructor), recognized directly by
      // `target.isStatic` + enclosing class name + library URI, mirroring
      // how `Result.ok`/`Result.err` are recognized by `target.isFactory`
      // above, just for a static method instead of a factory constructor.
      // `Port.outb` (void-returning) is recognized separately, in
      // `_lowerStatement`'s `ExpressionStatement` handling -- it has no
      // result value, so it cannot be lowered through this
      // value-producing dispatch (`_lowerExpression` always returns a
      // `DCValue`; dcc-lower/README.md already notes void-returning calls
      // need statement-context handling, which this is the first target to
      // actually need).
      if (target.isStatic &&
          target.enclosingClass?.name == 'Port' &&
          target.name.text == 'inb' &&
          target.enclosingLibrary.importUri == preludeUri) {
        final port = _lowerExpression(expr.arguments.positional.single);
        if (port.type != DCInt.u16) {
          throw DccLowerError(
            '"$context": Port.inb\'s port argument has type ${port.type}, '
            'expected u16',
          );
        }
        final dest = DCValue(_allocId(), DCInt.u8);
        _addInstr(PortIn(dest: dest, port: port));
        return dest;
      }

      // (M2, ADR-0018) A call to another user-defined `@bare` top-level
      // function -- recognized last among StaticInvocation shapes so it
      // can never shadow a prelude member (every case above already
      // returned by this point if the target was one). Direct call only,
      // by the target Procedure's own name -- Kernel IR has already fully
      // resolved `target` regardless of declaration order (a call to a
      // function declared later in the source works the same as one
      // declared earlier).
      if (_hasMarkerAnnotation(target.annotations, '_Bare', preludeUri)) {
        return _lowerBareCall(expr, target);
      }
    }

    if (expr is ConstructorInvocation) {
      final target = expr.target;
      final enclosingClass = target.enclosingClass;

      if (target.name.text == 'fromAddress' &&
          enclosingClass?.name == 'Pointer' &&
          target.enclosingLibrary.importUri == preludeUri) {
        final pointeeType = _pointeeTypeFromTypeArgs(expr.arguments.types);
        final address = _lowerExpression(expr.arguments.positional.single);
        final dest = DCValue(_allocId(), DCPointer(pointeeType));
        _addInstr(IntToPtr(dest: dest, address: address));
        return dest;
      }

      if (target.name.text == 'fromAddress' &&
          enclosingClass != null &&
          structLayouts.extendsStruct(enclosingClass)) {
        // A struct "instance" IS its base address at the DC-IR level (see
        // this file's header) -- constructing one is not a separate
        // operation, just the address value itself, flowing through
        // unchanged.
        return _lowerExpression(expr.arguments.positional.single);
      }

      if (enclosingClass != null && heapLayouts.extendsHeapObject(enclosingClass)) {
        return _lowerHeapConstruction(expr, enclosingClass);
      }

      // (M2, ADR-0023) `Weak<T>.fromStrong(target)` -> MakeWeak. The
      // constructor's own single positional argument is `target` (a
      // HeapObject reference) -- unlike Pointer<T>.fromAddress/
      // HeapObject construction, `Weak<T>` has no stored fields at all
      // (see the prelude's own doc comment), so there's no field-
      // initializer walk here, just one instruction.
      if (target.name.text == 'fromStrong' &&
          enclosingClass?.name == 'Weak' &&
          target.enclosingLibrary.importUri == preludeUri) {
        final object = _lowerExpression(expr.arguments.positional.single);
        if (object.type is! DCHeapPointer) {
          throw DccLowerError(
            '"$context": Weak.fromStrong(...) argument has non-DCHeapPointer '
            'type ${object.type} — only a HeapObject reference can be made weak',
          );
        }
        final dest = DCValue(_allocId(), const DCWeakPointer(DCVoid()));
        _addInstr(MakeWeak(dest: dest, object: object));
        return dest;
      }
    }

    if (expr is InstanceGet) {
      final target = expr.interfaceTarget;
      final enclosingClass = target.enclosingClass;

      // (M2, ADR-0023) `weakRef.value` -> WeakLoad. Checked before the
      // HeapObject/Struct field-read cases below since `value` is also
      // Pointer<T>'s own getter name (_isPointerValueMember) -- the URI +
      // enclosingClass.name == 'Weak' check keeps this from ever matching
      // an unrelated `.value` member.
      if (target.name.text == 'value' &&
          enclosingClass?.name == 'Weak' &&
          target.enclosingLibrary.importUri == preludeUri) {
        final weak = _lowerExpression(expr.receiver);
        if (weak.type is! DCWeakPointer) {
          throw DccLowerError(
            '"$context": .value read on a non-Weak DCValue (${weak.type})',
          );
        }
        final dest = DCValue(_allocId(), const DCHeapPointer(DCVoid()));
        _addInstr(WeakLoad(dest: dest, weak: weak));
        return dest;
      }

      if (_isPointerValueMember(target)) {
        final pointer = _lowerExpression(expr.receiver);
        if (pointer.type is! DCPointer) {
          throw DccLowerError(
            '"$context": .value read on a non-pointer DCValue (${pointer.type})',
          );
        }
        final pointeeType = (pointer.type as DCPointer).pointee;
        final dest = DCValue(_allocId(), pointeeType);
        _addInstr(Load(dest: dest, pointer: pointer));
        return dest;
      }

      if (enclosingClass != null && structLayouts.extendsStruct(enclosingClass)) {
        return _lowerStructFieldLoad(expr, enclosingClass);
      }

      if (enclosingClass != null && heapLayouts.extendsHeapObject(enclosingClass)) {
        return _lowerHeapFieldLoad(expr, enclosingClass);
      }
    }

    if (expr is InstanceInvocation) {
      final target = expr.interfaceTarget;
      if (target.name.text == 'propagate' &&
          target.enclosingClass?.name == 'Result' &&
          target.enclosingLibrary.importUri == preludeUri) {
        return _lowerPropagate(expr);
      }
    }

    throw DccLowerError(
      '"$context": unsupported expression $expr (${expr.runtimeType}) — see '
      'core/dcc-lower/README.md for exactly what is handled',
    );
  }

  /// `siblingFn(args...)` -- a call to another `@bare` top-level function
  /// (docs/decisions/0018-function-calls.md). `_lowerType` (reused here for
  /// the CALLEE's signature, not just this function's own) resolves scalar
  /// AND `HeapObject`-subclass parameter/return types (ADR-0019). A
  /// heap-typed argument passed to an `@owned` parameter (ADR-0021, spec
  /// §3.2 item 2) gets a `Retain` here UNLESS the argument expression is
  /// itself a known fresh-ownership source (`_isFreshHeapOwnership`) --
  /// same reasoning as `_lowerStatement`'s VariableDeclaration case: an
  /// `@owned` parameter is going to `Release` it, so if the caller ALSO
  /// still has an independent, still-tracked reference to the same value
  /// (an existing local, a field read -- anything that isn't fresh), that
  /// reference needs its own retain to avoid the callee's release
  /// under-counting it. A void-returning callee is deliberately NOT
  /// handled here -- this method is only reached from expression contexts
  /// that need a value back (`_lowerExpression`'s non-nullable return
  /// type); calling a void function as a bare statement would need
  /// separate `ExpressionStatement` handling that hasn't been written
  /// because no conformance target has needed it yet.
  DCValue _lowerBareCall(StaticInvocation expr, Procedure target) {
    final calleeFn = target.function;
    final returnType = calleeFn.returnType;
    if (returnType is VoidType) {
      throw DccLowerError(
        '"$context": call to "${target.name.text}", which returns void -- '
        'void-returning function calls are only supported as a top-level '
        'statement, not implemented yet (this call is used as an '
        'expression, which needs a value)',
      );
    }
    final calleeReturnType = _lowerType(
      returnType,
      context: '"${target.name.text}" return type (called from "$context")',
    );

    final calleeParams = calleeFn.positionalParameters;
    final callArgs = expr.arguments.positional;
    if (calleeParams.length != callArgs.length) {
      throw DccLowerError(
        '"$context": call to "${target.name.text}" passes ${callArgs.length} '
        'arguments, but it takes ${calleeParams.length}',
      );
    }

    final loweredArgs = <DCValue>[];
    // (Move semantics, docs/decisions/0031-move-semantics.md) Parallel to
    // loweredArgs -- records, per argument, whether the callee fully
    // consumes it (an @owned DCHeapPointer parameter) so dc-elide can
    // later tell a load-bearing borrowed pair apart from a redundant
    // owned-consuming one, which look identical as a plain opaque `Call`
    // otherwise.
    final argOwnership = <bool>[];
    for (var i = 0; i < calleeParams.length; i++) {
      final expectedType = _lowerType(
        calleeParams[i].type,
        context: '"${target.name.text}" param ${calleeParams[i].name} (called from "$context")',
      );
      final arg = _lowerExpression(callArgs[i]);
      if (arg.type != expectedType) {
        throw DccLowerError(
          '"$context": call to "${target.name.text}" passes argument $i of '
          'type ${arg.type} for a parameter declared $expectedType -- no '
          'implicit widening (same rule as arithmetic)',
        );
      }
      final isOwnedParam = _hasMarkerAnnotation(calleeParams[i].annotations, '_Owned', preludeUri);
      if (expectedType is DCHeapPointer && isOwnedParam && !_isFreshHeapOwnership(callArgs[i])) {
        _addInstr(Retain(object: arg));
      }
      // (ADR-0023) Same idea for a Weak<T>-typed @owned parameter, but
      // narrower: passing an EXISTING Weak<T> local would need its own
      // weak-count increment (a "weak retain") this project doesn't
      // implement yet (MakeWeak only accepts a DCHeapPointer source, not
      // an existing DCWeakPointer -- see the prelude's Weak<T> doc
      // comment on why weak-to-weak aliasing is unsupported). Only a
      // fresh source is allowed through; anything else throws rather than
      // silently double-dropping the weak count.
      if (expectedType is DCWeakPointer && isOwnedParam && !_isFreshHeapOwnership(callArgs[i])) {
        throw DccLowerError(
          '"$context": call to "${target.name.text}" passes an existing '
          'Weak<T> local to an @owned Weak<T> parameter -- only a fresh '
          'Weak.fromStrong(...) construction or a call returning Weak<T> '
          'can be passed directly (see docs/known-gaps.md)',
        );
      }
      // Only DCHeapPointer arguments record ownership for elision purposes
      // -- a DCWeakPointer @owned param has no elision story built yet
      // (weak-count elision is a separate, unstarted question), and
      // non-pointer types have no ARC traffic to elide in the first place.
      argOwnership.add(expectedType is DCHeapPointer && isOwnedParam);
      loweredArgs.add(arg);
    }

    final dest = DCValue(_allocId(), calleeReturnType);
    _addInstr(Call(dest: dest, targetName: target.name.text, args: loweredArgs, argOwnership: argOwnership));
    return dest;
  }

  DCValue _lowerU64Binary(
    StaticInvocation expr,
    void Function(DCValue dest, DCValue lhs, DCValue rhs) emit,
    DCType destType,
  ) {
    final args = expr.arguments.positional;
    if (args.length != 2) {
      throw DccLowerError(
        '"$context": ${expr.target.name.text} invocation with ${args.length} '
        'arguments, expected 2',
      );
    }
    final lhs = _lowerExpression(args[0]);
    final rhs = _lowerExpression(args[1]);
    final dest = DCValue(_allocId(), destType);
    emit(dest, lhs, rhs);
    return dest;
  }

  /// `Result.ok(x)` / `Result.err(x)` -> `MakeStruct` building a
  /// `{tag, payload}` value (tag 0 = Ok, 1 = Err). See
  /// docs/decisions/0014-result-value-representation.md.
  DCValue _lowerResultFactory(StaticInvocation expr, String factoryName) {
    final int tagBits;
    if (factoryName == 'ok') {
      tagBits = 0;
    } else if (factoryName == 'err') {
      tagBits = 1;
    } else {
      throw DccLowerError('"$context": unrecognized Result factory "$factoryName"');
    }

    final args = expr.arguments.positional;
    if (args.length != 1) {
      throw DccLowerError(
        '"$context": Result.$factoryName invocation with ${args.length} '
        'arguments, expected 1',
      );
    }
    final payload = _lowerExpression(args.single);

    final tag = DCValue(_allocId(), DCInt.u64);
    _addInstr(ConstInt(dest: tag, bits: tagBits));

    final dest = DCValue(_allocId(), resultStructType);
    _addInstr(MakeStruct(dest: dest, structType: resultStructType, fields: [tag, payload]));
    return dest;
  }

  /// `result.propagate()` — the named-method approximation for `?`
  /// (docs/escalations/0001-question-mark-syntax.md). Extracts the tag; if
  /// Err (1), returns the whole `Result` immediately from the enclosing
  /// function (which must itself declare `Result` as its return type —
  /// checked here, since unlike real `?`, Dart's own type checker does not
  /// enforce this for a plain method call); if Ok (0), continues with the
  /// extracted payload as this expression's value.
  DCValue _lowerPropagate(InstanceInvocation expr) {
    final resultValue = _lowerExpression(expr.receiver);
    if (resultValue.type != resultStructType) {
      throw DccLowerError(
        '"$context": .propagate() receiver has type ${resultValue.type}, expected Result',
      );
    }
    if (_declaredReturnType != resultStructType) {
      throw DccLowerError(
        '"$context": .propagate() used, but this function\'s return type is '
        '$_declaredReturnType, not Result — .propagate() can only early-'
        'return from a function that itself returns Result. Real `?` would '
        'have Dart\'s own type checker enforce this automatically; this '
        'named-method approximation does not, so dcc-lower checks it '
        'instead (see prelude.dart\'s note on Result.propagate).',
      );
    }

    final tag = DCValue(_allocId(), DCInt.u64);
    _addInstr(ExtractField(dest: tag, struct: resultValue, fieldIndex: 0));
    final payload = DCValue(_allocId(), DCInt.u64);
    _addInstr(ExtractField(dest: payload, struct: resultValue, fieldIndex: 1));
    final zero = DCValue(_allocId(), DCInt.u64);
    _addInstr(ConstInt(dest: zero, bits: 0));
    final isOk = DCValue(_allocId(), const DCBool());
    _addInstr(ICmp(dest: isOk, predicate: ICmpPredicate.eq, lhs: tag, rhs: zero));

    final errBlockId = _allocBlockId();
    final okBlockId = _allocBlockId();
    _addInstr(
      CondBranch(cond: isOk, trueTarget: okBlockId, trueArgs: const [], falseTarget: errBlockId, falseArgs: const []),
    );
    _finishBlock();

    _startBlock(errBlockId, const []);
    _addInstr(Return(value: resultValue));
    _finishBlock();

    _startBlock(okBlockId, const []);
    // payload was computed in the pre-branch block, which dominates
    // okBlockId (its only predecessor) -- referencing it directly by SSA
    // name here is valid, no phi needed (same reasoning core/backend's
    // trapping-arithmetic "ok" block already relies on).
    return payload;
  }

  /// `structInstance.field` -> `address + offset -> pointer -> load`. Reuses
  /// ConstInt/IAdd/IntToPtr/Load exactly as `Pointer<T>.value`'s getter
  /// does — see this file's header. Unrelated to `Result`'s MakeStruct
  /// pattern above (ADR-0011 vs ADR-0014 — both "struct-shaped", different
  /// DC-IR mechanisms, on purpose).
  DCValue _lowerStructFieldLoad(InstanceGet expr, Class structClass) {
    final field = _findField(structClass, expr.interfaceTarget.name.text);
    final baseAddress = _lowerExpression(expr.receiver);
    final fieldPointer = _emitFieldPointer(baseAddress, field);
    final dest = DCValue(_allocId(), field.type);
    _addInstr(Load(dest: dest, pointer: fieldPointer));
    return dest;
  }

  /// `structInstance.field = value` -> `address + offset -> pointer -> store`.
  void _lowerStructFieldStore(InstanceSet expr, Class structClass) {
    final field = _findField(structClass, expr.interfaceTarget.name.text);
    final baseAddress = _lowerExpression(expr.receiver);
    final fieldPointer = _emitFieldPointer(baseAddress, field);
    final value = _lowerExpression(expr.value);
    _addInstr(Store(pointer: fieldPointer, value: value));
  }

  _StructField _findField(Class structClass, String name) {
    final fields = structLayouts.layoutFor(structClass);
    for (final field in fields) {
      if (field.name == name) return field;
    }
    throw DccLowerError(
      '"$context": "${structClass.name}" has no @packed field "$name" — '
      'this should be unreachable (front_end already resolved the getter/'
      'setter), so this indicates a bug in _StructLayouts.layoutFor',
    );
  }

  /// `HeapClass(args...)` -> `Alloc` + one `PtrOffset`+`Store` per field
  /// initializer (ADR-0016). Only the `ThisClass(this.field, ...)`
  /// shorthand is handled: each `FieldInitializer.value` must be a direct
  /// `VariableGet` of one of the constructor's own positional parameters
  /// (mapped to the call site's already-lowered arguments by position) —
  /// anything else (real computation in an initializer) throws.
  DCValue _lowerHeapConstruction(ConstructorInvocation expr, Class heapClass) {
    final fields = heapLayouts.layoutFor(heapClass);
    final payloadSize = heapLayouts.payloadSizeBytes(heapClass);

    // DCVoid as the DCHeapPointer's pointee is a placeholder -- DC-IR
    // doesn't yet track a heap object's full field layout as part of its
    // own type (GAP-0003, ClassInfo still deferred); field access below
    // goes through _HeapLayouts (dcc-lower-side), not the DCType. Matches
    // the hand-built ADR-0015 leak test's own placeholder.
    final dest = DCValue(_allocId(), const DCHeapPointer(DCVoid()));
    // (ADR-0022) destructorName is resolved once here, at the ONE place
    // this class's concrete identity is statically known for sure --
    // Release's own codegen needs no class information at all, since
    // Alloc already wrote this into the object's cls header field.
    _addInstr(
      Alloc(
        dest: dest,
        payloadSizeBytes: payloadSize,
        destructorName: heapLayouts.destructorNameFor(heapClass),
      ),
    );

    final ctor = expr.target;
    final ctorParams = ctor.function.positionalParameters;
    if (ctorParams.length != expr.arguments.positional.length) {
      throw DccLowerError(
        '"$context": ${heapClass.name} constructor takes ${ctorParams.length} '
        'positional params, call site gives ${expr.arguments.positional.length}',
      );
    }
    final paramToArg = <VariableDeclaration, DCValue>{};
    for (var i = 0; i < ctorParams.length; i++) {
      paramToArg[ctorParams[i]] = _lowerExpression(expr.arguments.positional[i]);
    }

    for (final init in ctor.initializers) {
      if (init is SuperInitializer) continue; // HeapObject's own trivial super() -- nothing to lower
      if (init is! FieldInitializer) {
        throw DccLowerError(
          '"$context": ${heapClass.name} constructor has an unsupported '
          'initializer ${init.runtimeType} — only field initializers and a '
          'trivial super() call are handled at M2',
        );
      }
      final fieldName = init.field.name.text;
      final field = fields.firstWhere(
        (f) => f.name == fieldName,
        orElse: () => throw DccLowerError(
          '"$context": ${heapClass.name}.$fieldName has no layout entry — '
          'dcc-lower bug in _HeapLayouts',
        ),
      );

      final initValue = init.value;
      if (initValue is! VariableGet || !paramToArg.containsKey(initValue.variable)) {
        throw DccLowerError(
          '"$context": ${heapClass.name}.$fieldName\'s initializer is not a '
          'direct constructor-parameter reference ($initValue, '
          '${initValue.runtimeType}) — only the `ThisClass(this.field)` '
          'shorthand is handled at M2, see '
          'docs/decisions/0016-heap-object-field-access.md',
        );
      }
      final value = paramToArg[initValue.variable]!;

      // (M2, ADR-0020) Embedding a heap-typed field: `value` came from a
      // constructor PARAMETER, which is always borrowed (bound directly in
      // `lower()`, never tracked/owned the way a local is -- ADR-0019).
      // Storing a borrowed reference into a field this new object now
      // independently outlives needs its own Retain, exactly like binding
      // one to a local does (the generalized check in `_lowerStatement`'s
      // VariableDeclaration case) -- otherwise the field pointer dangles
      // the moment whichever caller-side owner passed it in releases its
      // own reference.
      if (field.type is DCHeapPointer) {
        _addInstr(Retain(object: value));
      }

      final fieldPtr = DCValue(_allocId(), DCPointer(field.type));
      _addInstr(PtrOffset(dest: fieldPtr, base: dest, offsetBytes: field.offset));
      _addInstr(Store(pointer: fieldPtr, value: value));
    }

    return dest;
  }

  /// `heapInstance.field` -> `PtrOffset` + `Load`, reading directly off the
  /// `DCHeapPointer` (no address-materialization step needed, unlike
  /// `@packed` struct fields which start from a raw `u64` -- ADR-0016).
  DCValue _lowerHeapFieldLoad(InstanceGet expr, Class heapClass) {
    final field = _findHeapField(heapClass, expr.interfaceTarget.name.text);
    final objectPtr = _lowerExpression(expr.receiver);
    final fieldPtr = DCValue(_allocId(), DCPointer(field.type));
    _addInstr(PtrOffset(dest: fieldPtr, base: objectPtr, offsetBytes: field.offset));
    final dest = DCValue(_allocId(), field.type);
    _addInstr(Load(dest: dest, pointer: fieldPtr));
    return dest;
  }

  _StructField _findHeapField(Class heapClass, String name) {
    final fields = heapLayouts.layoutFor(heapClass);
    for (final field in fields) {
      if (field.name == name) return field;
    }
    throw DccLowerError(
      '"$context": "${heapClass.name}" has no field "$name" — this should '
      'be unreachable (front_end already resolved the field access), so '
      'this indicates a bug in _HeapLayouts.layoutFor',
    );
  }

  /// Emits `ConstInt(offset) -> IAdd(base, offset) -> IntToPtr` and returns
  /// the resulting typed pointer DCValue. `Overflow.wrapping` on the
  /// address addition is deliberate: this is compiler-generated address
  /// arithmetic, not user-source `+` (no DCDART_SPEC.md §4.1 trapping
  /// annotation applies to it) -- wrapping is the standard, expected
  /// semantic for pointer/address math in every systems language DCDart is
  /// drawing from.
  DCValue _emitFieldPointer(DCValue baseAddress, _StructField field) {
    if (field.offset == 0) {
      final ptr = DCValue(_allocId(), DCPointer(field.type));
      _addInstr(IntToPtr(dest: ptr, address: baseAddress));
      return ptr;
    }
    final offsetConst = DCValue(_allocId(), DCInt.u64);
    _addInstr(ConstInt(dest: offsetConst, bits: field.offset));
    final addr = DCValue(_allocId(), DCInt.u64);
    _addInstr(
      IAdd(dest: addr, lhs: baseAddress, rhs: offsetConst, overflow: Overflow.wrapping),
    );
    final ptr = DCValue(_allocId(), DCPointer(field.type));
    _addInstr(IntToPtr(dest: ptr, address: addr));
    return ptr;
  }

  bool _isPointerValueMember(Member member) =>
      member.name.text == 'value' &&
      member.enclosingClass?.name == 'Pointer' &&
      member.enclosingLibrary.importUri == preludeUri;

  DCType _pointeeTypeFromTypeArgs(List<DartType> typeArgs) {
    if (typeArgs.length != 1) {
      throw DccLowerError(
        '"$context": Pointer<...> constructor with ${typeArgs.length} type '
        'arguments, expected exactly 1',
      );
    }
    return _lowerType(typeArgs.single, context: '$context Pointer type argument');
  }

  DCType _lowerType(DartType type, {required String context}) {
    if (type is ExtensionType) {
      final decl = type.extensionTypeDeclaration;
      if (decl.enclosingLibrary.importUri == preludeUri) {
        switch (decl.name) {
          case 'u64':
            return DCInt.u64;
          case 'u32':
            return DCInt.u32;
          case 'u16':
            return DCInt.u16;
          case 'u8':
            return DCInt.u8;
        }
      }
    }
    if (type is InterfaceType) {
      // Safe to inspect .classNode here: Result and any HeapObject subclass
      // are declared as part of this same component (the prelude and the
      // source file itself), never an unbound platform reference --
      // verified empirically before writing this (see ADR-0014), unlike
      // e.g. `bool`/`int` which crash under --no-link-platform
      // (kernel_frontend.dart).
      final cls = type.classNode;
      if (cls.name == 'Result' && cls.enclosingLibrary.importUri == preludeUri) {
        return resultStructType;
      }
      // (M2, ADR-0019) A HeapObject subclass used as a parameter/return
      // type -- e.g. `u64 readBox(Box b)`. Same placeholder-pointee
      // DCHeapPointer(DCVoid()) `_lowerHeapConstruction` already uses (GAP-
      // 0003: DC-IR doesn't track a heap object's concrete field layout as
      // part of its own type yet) -- field access on a value of this type
      // still works because `_lowerHeapFieldLoad` determines which class's
      // layout to use from the Kernel IR access site itself
      // (`InstanceGet.interfaceTarget.enclosingClass`), never from the
      // DCValue's own DCType, so the placeholder pointee loses no
      // information anything here actually needs.
      if (heapLayouts.extendsHeapObject(cls)) {
        return const DCHeapPointer(DCVoid());
      }
      // (M2, ADR-0023) `Weak<T>` in parameter/return position -- same
      // placeholder-pointee reasoning as DCHeapPointer above; nothing
      // downstream needs the concrete pointee type recorded in the DCType
      // itself (MakeWeak/WeakLoad/DropWeak all operate purely on the
      // header, never on the payload's field layout).
      if (cls.name == 'Weak' && cls.enclosingLibrary.importUri == preludeUri) {
        return const DCWeakPointer(DCVoid());
      }
    }
    throw DccLowerError(
      '"$context": unsupported type $type (${type.runtimeType}) — dcc-lower '
      'only understands u8/u32/u64/Result/HeapObject subclasses/Weak<T> '
      'from the DCDart prelude so far, see core/dcc-lower/README.md',
    );
  }
}

class DccLowerError extends Error {
  final String message;
  DccLowerError(this.message);

  @override
  String toString() => 'DccLowerError: $message';
}
