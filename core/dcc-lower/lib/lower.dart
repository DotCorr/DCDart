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

    // Only `targetLibrary`'s procedures are lowered (see the loop below), so
    // a `@bare` function in an IMPORTED library is not compiled into this
    // object at all. Before this check that happened SILENTLY: the build
    // succeeded, the symbol simply was not in the output, and the generated
    // header did not mention it either. Splitting a program across files
    // quietly deleted half of its API — a function that vanishes with no
    // diagnostic is strictly worse than a compile error (GAP-0028, reported
    // by oscortex_core, which worked around it with `part`/`part of`).
    //
    // This does not FIX multi-library compilation; it converts a silent trap
    // into a diagnostic that names exactly what was dropped and what to do
    // instead.
    _rejectBareFunctionsInImportedLibraries(
      component,
      targetLibrary: targetLibrary,
      preludeUri: preludeUri,
    );

    final structLayouts = _StructLayouts(preludeUri);
    final heapLayouts = _HeapLayouts(preludeUri);

    // (ADR-0038) External C-ABI symbols FIRST, before any function body is
    // lowered, for two reasons: a call site needs to know the target was
    // really declared (not merely annotated somewhere unreachable), and a
    // signature this backend cannot honestly express must fail at the
    // DECLARATION, naming it, rather than at whichever call site happens to
    // be lowered first.
    final externFunctions = _collectExternDeclarations(
      targetLibrary,
      preludeUri: preludeUri,
      heapLayouts: heapLayouts,
    );
    final externNames = {for (final e in externFunctions) e.linkName};

    // Read-only statics (ADR-0040). Collected BEFORE function bodies are
    // lowered, because a body referencing one needs the symbol name to
    // already be known -- same ordering reason ADR-0038 collects externs
    // first.
    final globals = _collectRodataGlobals(targetLibrary, preludeUri: preludeUri);
    final globalNames = {for (final g in globals) g.linkName};

    // A `Ref('name')` relocation is resolved against this unit's own
    // `@rodata` declarations. Checked HERE, after every global is collected,
    // so a table may reference one declared later in the file (and two
    // tables may reference each other -- symbol-name references need no
    // topological order). An unresolved name would otherwise reach `clang`
    // as `use of undefined value '@name'`, which names neither DCDart nor
    // the declaration that was meant.
    for (final global in globals) {
      _checkRelocationTargets(global.initializer, global.linkName, globalNames);
    }

    final functions = <DCFunction>[];
    for (final proc in targetLibrary.procedures) {
      if (!_hasMarkerAnnotation(proc.annotations, '_Bare', preludeUri)) continue;
      if (proc.isExternal) {
        // `@bare external` is the one genuinely ambiguous shape: it has no
        // body to lower, but `@bare` means "lower this as a function". Say
        // so, rather than crashing later on a null body.
        throw DccLowerError(
          '"${proc.name.text}" is declared `@bare external` — a body-less '
          'declaration of a symbol defined elsewhere is `@extern`, not '
          '`@bare` (docs/decisions/0038-extern-symbols-and-linking.md)',
        );
      }
      functions.add(
        _BareFunctionLowerer(proc, preludeUri, structLayouts, heapLayouts, externNames, globalNames).lower(),
      );
    }

    // (ADR-0043) Instance methods on HeapObject subclasses, lowered as
    // ordinary functions with the receiver as parameter 0. Collected AFTER
    // the top-level walk so a method may call a top-level function and vice
    // versa -- both end up in the same `functions` list and `Call` resolves
    // by name at emission.
    final methodNames = <Procedure, String>{};
    for (final cls in targetLibrary.classes) {
      if (!heapLayouts.extendsHeapObject(cls)) continue;
      for (final proc in cls.procedures) {
        if (proc.isStatic || proc.isAbstract || proc.isExternal) continue;
        if (proc.kind != ProcedureKind.Method) {
          // Getters/setters/operators on a HeapObject are not lowered yet;
          // saying so beats emitting nothing and letting the call site fail
          // with a confusing "has no field" error later.
          throw DccLowerError(
            '"${cls.name}.${proc.name.text}" is a ${proc.kind.name}; only '
            'plain instance methods are lowered on a HeapObject subclass '
            '(docs/decisions/0043-instance-methods.md)',
          );
        }
        methodNames[proc] = methodLinkName(cls.name, proc.name.text);
      }
    }
    for (final entry in methodNames.entries) {
      functions.add(
        _BareFunctionLowerer(
          entry.key,
          preludeUri,
          structLayouts,
          heapLayouts,
          externNames,
          globalNames,
          entry.key.enclosingClass,
        ).lower(linkNameOverride: entry.value),
      );
    }

    if (functions.isEmpty) {
      throw DccLowerError('no @bare top-level function found in $dartSourcePath');
    }

    // A symbol cannot be both defined here and imported from elsewhere. The
    // link would resolve to this module's own definition and silently ignore
    // the declaration, which is the kind of quiet disagreement extern
    // declarations exist to prevent.
    final definedNames = {for (final f in functions) f.linkName};
    for (final name in externNames) {
      if (definedNames.contains(name)) {
        throw DccLowerError(
          '"$name" is declared `@extern` but this compilation unit also '
          'defines a `@bare` function with that name — one symbol cannot be '
          'both imported and exported by the same object file',
        );
      }
    }

    for (final name in globalNames) {
      if (definedNames.contains(name) || externNames.contains(name)) {
        throw DccLowerError(
          '"$name" is a `@rodata` global but is also a function name in this '
          'compilation unit — symbol names are emitted verbatim (spec §9), so '
          'the two would collide in the object file',
        );
      }
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

    return DCModule(
      name: dartSourcePath,
      functions: elidedFunctions,
      externFunctions: externFunctions,
      globals: globals,
    );
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

/// Collects every `@extern external` declaration in [library] as a
/// [DCExternFunction] (DCDART_SPEC.md §9,
/// docs/decisions/0038-extern-symbols-and-linking.md).
///
/// This function's OUTPUT is load-bearing beyond codegen: it is the exact set
/// of undefined symbols the emitted object file is permitted to carry, which
/// `dcc` writes out as a manifest and `scripts/verify-freestanding.sh` checks
/// `nm -u` against (CLAUDE.md rule 1,
/// docs/escalations/0003-extern-c-calls-vs-freestanding.md). Every rejection
/// below is therefore a rejection of a symbol that would otherwise have to be
/// permitted, not merely a codegen limitation.
List<DCExternFunction> _collectExternDeclarations(
  Library library, {
  required Uri preludeUri,
  required _HeapLayouts heapLayouts,
}) {
  final result = <DCExternFunction>[];
  final seen = <String>{};

  for (final proc in library.procedures) {
    if (!_hasMarkerAnnotation(proc.annotations, '_Extern', preludeUri)) continue;
    final name = proc.name.text;

    // `external` is Dart's own "declared here, defined elsewhere" keyword,
    // and front_end already guarantees such a declaration has no body.
    // Requiring it means the SOURCE reads as a declaration to a human too,
    // not just to dcc-lower — an `@extern` on something with a body would be
    // a function whose body is silently discarded.
    if (!proc.isExternal) {
      throw DccLowerError(
        '"$name" is annotated `@extern` but is not declared `external` — an '
        'external C symbol has no body here. Write: '
        '`@extern external <type> $name(...);`',
      );
    }
    if (proc.function.body != null) {
      throw DccLowerError(
        '"$name" is `@extern external` but still carries a body in Kernel IR '
        '— dcc-lower will not silently discard it',
      );
    }
    if (_hasMarkerAnnotation(proc.annotations, '_Bare', preludeUri)) {
      throw DccLowerError(
        '"$name" is annotated both `@extern` and `@bare` — a symbol is either '
        'defined by this compilation unit (`@bare`) or imported from another '
        'object file (`@extern`), never both',
      );
    }
    if (!proc.isStatic || proc.kind != ProcedureKind.Method) {
      throw DccLowerError(
        '"$name" is `@extern` but is not a plain top-level function '
        '(kind ${proc.kind}) — getters, setters, operators and instance '
        'members have no C-ABI spelling',
      );
    }
    if (!seen.add(name)) {
      throw DccLowerError('"$name" is declared `@extern` more than once');
    }

    final fn = proc.function;
    if (fn.namedParameters.isNotEmpty || fn.requiredParameterCount != fn.positionalParameters.length) {
      throw DccLowerError(
        '"$name": an `@extern` C symbol takes positional, required '
        'parameters only — C has no named or optional parameters',
      );
    }
    if (fn.typeParameters.isNotEmpty) {
      throw DccLowerError(
        '"$name": an `@extern` C symbol cannot be generic — C symbols are '
        'monomorphic by construction',
      );
    }

    final paramTypes = <DCType>[];
    for (final param in fn.positionalParameters) {
      paramTypes.add(
        _externSignatureType(
          param.type,
          preludeUri: preludeUri,
          heapLayouts: heapLayouts,
          context: '"$name" param ${param.name}',
          allowVoid: false,
        ),
      );
    }
    final returnType = _externSignatureType(
      fn.returnType,
      preludeUri: preludeUri,
      heapLayouts: heapLayouts,
      context: '"$name" return type',
      allowVoid: true,
    );

    result.add(
      DCExternFunction(linkName: name, paramTypes: paramTypes, returnType: returnType),
    );
  }

  return result;
}

/// [_lowerSignatureType] plus the two refusals that are specific to a symbol
/// crossing OUT of DCDart into code the compiler cannot see.
///
/// `HeapObject` and `Weak<T>` are rejected on purpose. They are ARC-managed
/// (spec §3.1): handing one to a C function raises an ownership question —
/// does the callee consume the reference, borrow it, or retain it? — that
/// nothing in this project has decided. `@owned` (ADR-0021) answers it for
/// DCDart-to-DCDart calls precisely because both sides are compiled here;
/// neither side of that machinery exists for C. Picking a convention silently
/// would be a memory-model decision made by an implementation unit, which
/// CLAUDE.md rule 4 forbids. Recorded as a sub-item of GAP-0019 instead.
///
/// NOTE the asymmetry with `c_header.dart` (ADR-0034), which DOES map a
/// `DCHeapPointer` — to an opaque `DCHeapRef` that C is told never to
/// dereference or free. That direction is safe because the DCDart side still
/// owns the object and C merely holds a token. Inbound, C would be the one
/// receiving something it might store, free or race on.
DCType _externSignatureType(
  DartType type, {
  required Uri preludeUri,
  required _HeapLayouts heapLayouts,
  required String context,
  required bool allowVoid,
}) {
  if (type is VoidType) {
    if (allowVoid) return const DCVoid();
    throw DccLowerError('$context: void is not a parameter type');
  }
  final lowered = _lowerSignatureType(
    type,
    preludeUri: preludeUri,
    heapLayouts: heapLayouts,
    context: context,
  );
  if (lowered is DCHeapPointer || lowered is DCWeakPointer) {
    throw DccLowerError(
      '$context: an ARC-managed HeapObject/Weak<T> cannot appear in an '
      '`@extern` C signature — the ownership convention across that boundary '
      'is undecided (docs/known-gaps.md GAP-0019, CLAUDE.md rule 4). Pass a '
      'plain sized integer or a Pointer<T> instead',
    );
  }
  return lowered;
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

  /// The receiver value when lowering an instance method (ADR-0043).
  DCValue? _thisValue;

  /// Where a `break`/`continue` targeting a given label must branch to, and
  /// which loop-carried variables that edge has to carry (ADR-0047).
  ///
  /// Kernel spells BOTH as `BreakStatement`; they differ only in which
  /// `LabeledStatement` is the target. A label wrapping the WHILE means
  /// `break` (jump past the loop); a label wrapping the loop's BODY means
  /// `continue` (jump to the header). Nothing else distinguishes them.
  final Map<LabeledStatement, ({BlockId target, List<VariableDeclaration> vars})>
      _labelTargets = {};
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

  /// The link names of every `@extern` declaration collected at module scope
  /// (ADR-0038). A call site checks membership here rather than trusting the
  /// annotation on the resolved target alone: Kernel IR will happily resolve
  /// a `StaticInvocation` to an `@extern` procedure in a DIFFERENT library
  /// (an import), which this module never scanned and therefore never
  /// declared, never emitted a `declare` for, and never put in the manifest
  /// `verify-freestanding.sh` reads. That would be an undefined symbol
  /// nobody accounted for — the exact failure the manifest exists to prevent.
  final Set<String> externNames;

  /// Symbol names of this module's `@rodata` globals (ADR-0040). A
  /// `StaticGet` of one lowers to its address; a `StaticGet` of anything
  /// else is still rejected.
  final Set<String> globalNames;

  /// The enclosing class when lowering an INSTANCE METHOD (ADR-0043), null
  /// for a top-level `@bare` function.
  ///
  /// A method is lowered as an ordinary function whose FIRST parameter is
  /// the receiver — the same shape `_buildDestructor` already synthesizes
  /// for the destructor cascade (ADR-0022), and the same shape C uses. No
  /// dynamic dispatch is involved: every call site knows the concrete class
  /// statically, exactly as ADR-0022 observed for destructors.
  final Class? receiverClass;

  _BareFunctionLowerer(
    this.proc,
    this.preludeUri,
    this.structLayouts,
    this.heapLayouts,
    this.externNames,
    this.globalNames, [
    this.receiverClass,
  ]);

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

  DCFunction lower({String? linkNameOverride}) {
    final fn = proc.function;

    final paramTypes = <DCType>[];
    final paramValues = <DCValue>[];

    // (ADR-0043) An instance method's receiver is param 0. Kernel does NOT
    // put `this` in `positionalParameters` -- it is implicit, reached via
    // `ThisExpression` -- so it is prepended here and bound to `_thisValue`
    // rather than to a VariableDeclaration.
    final cls = receiverClass;
    if (cls != null) {
      final selfType = DCHeapPointer(DCVoid());
      final selfValue = DCValue(_allocId(), selfType);
      _thisValue = selfValue;
      paramTypes.add(selfType);
      paramValues.add(selfValue);
    }

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
      linkName: linkNameOverride ?? context,
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
          // `Pointer<T>.value = x` is DCDart's MMIO mechanism (spec §6), so
          // it is volatile: the optimizer may not drop, duplicate or reorder
          // a hardware register write (ADR-0041).
          _addInstr(Store(pointer: pointer, value: value, isVolatile: true));
          return;
        }

        if (enclosingClass != null && structLayouts.extendsStruct(enclosingClass)) {
          _lowerStructFieldStore(expr, enclosingClass);
          return;
        }

        if (enclosingClass != null && heapLayouts.extendsHeapObject(enclosingClass)) {
          _lowerHeapFieldStore(expr, enclosingClass);
          return;
        }
      }
      // (M2, ADR-0027) `x = <expr>;` -- reassigning an existing non-final
      // local. DC-IR is SSA (dc-ir/README.md): there is no single fixed
      // SSA value a "mutable variable" keeps across its lifetime.
      // Reassignment is just rebinding `_values[variable]` to point at a
      // freshly-lowered DCValue -- every SUBSEQUENT VariableGet naturally
      // sees the new one, since `_values` is consulted lazily. Safe for
      // straight-line code; a reassignment inside an if-branch that falls
      // through (rather than returning) is the classic SSA phi/merge
      // problem -- `_lowerIf` (ADR-0032) handles it by threading the
      // reassigned value through a real DC-IR merge block, the same
      // block-parameter mechanism `_lowerWhile`'s own header already uses.
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
        // (ADR-0048) Reassigning a HEAP-typed local is an ownership
        // transfer, and takes exactly the same policy as a heap-typed field
        // store: retain the new value unless it is already a fresh +1,
        // then release the old one. Retain-before-release so `x = x` cannot
        // free the object between the two steps.
        if (oldValue.type is DCHeapPointer) {
          final newValue = _lowerExpression(expr.value);
          if (newValue.type is! DCHeapPointer) {
            throw DccLowerError(
              '"$context": assigning ${newValue.type} to heap-typed local '
              '"${variable.name}"',
            );
          }
          if (!_isFreshHeapOwnership(expr.value)) {
            _addInstr(Retain(object: newValue));
          }
          _addInstr(Release(object: oldValue));
          _values[variable] = newValue;
          return;
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
            (target.name.text == 'outb' ||
                target.name.text == 'outw' ||
                target.name.text == 'outl') &&
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
          final expectedValueType = switch (target.name.text) {
            'outw' => DCInt.u16,
            'outl' => DCInt.u32,
            _ => DCInt.u8,
          };
          if (value.type != expectedValueType) {
            throw DccLowerError(
              '"$context": Port.${target.name.text}\'s value argument has '
              'type ${value.type}, expected $expectedValueType',
            );
          }
          _addInstr(PortOut(port: port, value: value));
          return;
        }

        // (ADR-0038) A call, as a statement, to a `@bare` sibling or an
        // `@extern` C symbol. This is where a void-returning callee is
        // finally reachable in general — ADR-0018 recorded the gap, ADR-0029
        // opened a single hardcoded hole in it for `Port.outb`, and `void`
        // being the single most common C return type is what made the
        // general case worth building.
        //
        // VOID ONLY, deliberately. Discarding a non-void result is legal
        // Dart, but a discarded `HeapObject` return is a leak under this
        // project's naive release policy (ADR-0016: only values bound to a
        // tracked local are ever released), and silently leaking is worse
        // than refusing. Scalar discards are refused too, for one rule
        // instead of two — bind the result to a local, which costs nothing.
        final isBare = _hasMarkerAnnotation(target.annotations, '_Bare', preludeUri);
        final isExtern = _hasMarkerAnnotation(target.annotations, '_Extern', preludeUri);
        if (isBare || isExtern) {
          if (target.function.returnType is! VoidType) {
            throw DccLowerError(
              '"$context": "${target.name.text}" returns a value, but its '
              'result is discarded here — bind it to a local '
              '(`final _unused = ${target.name.text}(...);`). Only '
              'void-returning calls may stand alone as a statement',
            );
          }
          _lowerCallTo(expr, target, allowVoid: true);
          return;
        }
      }
      throw DccLowerError(
        '"$context": unsupported expression statement $expr '
        '(${expr.runtimeType}) — M1 only understands `pointer.value = x;`, '
        '`structInstance.field = x;`, `heapInstance.field = x;` (scalar '
        'fields only), scalar local reassignment (`x = <expr>;`), '
        '`Port.outb(port, value);`, and a call to a `@bare` or `@extern` '
        'function as a statement',
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

    // (ADR-0050) `for (init; cond; update) body` desugars to the `while`
    // machinery rather than getting its own lowering:
    //
    //     init;  while (cond) { body; update; }
    //
    // Everything `_lowerWhile` already handles then applies unchanged --
    // loop-carried variables, nesting (ADR-0044), break/continue (ADR-0047),
    // heap-typed locals (ADR-0048). Writing a second loop lowering would have
    // meant re-deriving all of that and getting one of them subtly different.
    //
    // NOTE the update goes at the END of the body, which is where `continue`
    // makes the difference: Dart's `continue` in a `for` runs the update
    // before re-testing, and appending it to the body preserves that only
    // because `continue` targets the body's own label, which sits OUTSIDE
    // this appended block. Verified by test rather than by reasoning.
    if (stmt is ForStatement) {
      _lowerFor(stmt);
      return;
    }

    // (ADR-0047) A label wrapping a `while` is the `break` target. Pass it
    // down so `_lowerWhile` can register it against its exit block; a label
    // wrapping anything else has no loop to bind to and is just lowered
    // through.
    if (stmt is LabeledStatement) {
      final body = stmt.body;
      if (body is WhileStatement) {
        _lowerWhile(body, breakLabel: stmt);
        return;
      }
      if (body is ForStatement) {
        // (ADR-0050) A `for` gets the same label treatment as a `while` --
        // the CFE wraps both when the loop contains a `break`.
        _lowerFor(body, breakLabel: stmt);
        return;
      }
      _lowerStatement(body);
      return;
    }

    if (stmt is BreakStatement) {
      final entry = _labelTargets[stmt.target];
      if (entry == null) {
        throw DccLowerError(
          '"$context": `break`/`continue` targets a label that is not a '
          'loop this function is lowering. Labelled `break` to an arbitrary '
          'statement is not supported (ADR-0047).',
        );
      }
      // Carry the CURRENT values of the loop variables across the edge --
      // the whole reason the exit block needs parameters at all.
      _addInstr(Branch(
        target: entry.target,
        args: [for (final v in entry.vars) _values[v]!],
      ));
      _finishBlock();
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

  /// `if (cond) { thenBranch } [else { elseBranch }]`. Three shapes:
  ///   - if/else, both branches terminate: no fallthrough after the if:
  ///     subsequent statements (if any) are unreachable and throw.
  ///   - if without else, then-branch terminates, no reassignment escapes:
  ///     the false path IS the fallthrough — becomes the new open "current"
  ///     block subsequent statements continue into. The guard-clause
  ///     pattern `Result`-returning functions use with `.propagate()`.
  ///   - (ADR-0032) either branch falls through instead of terminating —
  ///     a plain conditional reassignment (`if (cond) { x = 1; } else
  ///     { x = 2; }`, with or without an explicit `else`) — merges back
  ///     into a real DC-IR merge block, using the exact same block-
  ///     parameter mechanism `_lowerWhile`'s own header already uses.
  ///     Scalar (`DCInt`) reassignments only, same rule as ADR-0027; a
  ///     heap/weak local declared inside a branch that falls through
  ///     (rather than returning) is not supported yet — nothing would
  ///     release it, since the naive release policy only fires on a real
  ///     `return` (docs/known-gaps.md).
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

    // (ADR-0032) Merge-candidate scalars: every local reassigned anywhere
    // in EITHER branch, already tracked before this `if`. Computed UP
    // FRONT, before lowering either branch — a reassignment can't change a
    // variable's type (ADR-0027), so the merge block's param types are
    // already knowable from `_values` as it stands right now. Reuses
    // `_collectLoopCarriedCandidates` — the exact same "which locals get
    // reassigned in this subtree" scan `_lowerWhile` already uses for its
    // own header params, including its throw-on-nested-while scope cut
    // (composing a nested loop's own header merge with an if/else merge
    // in the same pass is real, separate work, not attempted here).
    final mergeCandidates = <VariableDeclaration>{};
    _collectLoopCarriedCandidates(stmt.then, mergeCandidates);
    if (otherwise != null) {
      _collectLoopCarriedCandidates(otherwise, mergeCandidates);
    }
    final valuesBeforeIf = Map<VariableDeclaration, DCValue>.from(_values);
    final mergeVars = <VariableDeclaration>[
      for (final v in mergeCandidates)
        if (valuesBeforeIf.containsKey(v)) v,
    ];
    for (final v in mergeVars) {
      if (valuesBeforeIf[v]!.type is! DCInt) {
        throw DccLowerError(
          '"$context": "${v.name}" (type ${valuesBeforeIf[v]!.type}) is reassigned in a '
          'branch of this if/else that falls through -- only scalar '
          '(u8/u16/u32/u64) locals can be reassigned this way, same rule '
          'as ADR-0027\'s straight-line reassignment',
        );
      }
    }
    final mergeBlockId = _allocBlockId();
    final mergeParams = [
      for (final v in mergeVars) DCValue(_allocId(), valuesBeforeIf[v]!.type),
    ];

    // Closes the CURRENTLY open (fallen-through) branch by branching into
    // the merge block, passing each merge variable's current value.
    void branchToMerge(String branchName, int heapLocalsBefore, int weakLocalsBefore) {
      if (_heapLocals.length != heapLocalsBefore || _weakLocals.length != weakLocalsBefore) {
        throw DccLowerError(
          '"$context": a heap- or weak-typed local was declared in an '
          'if-branch ($branchName) that falls through to code after the '
          'if -- not supported yet, see docs/known-gaps.md',
        );
      }
      final mergeArgs = [for (final v in mergeVars) _values[v]!];
      _addInstr(Branch(target: mergeBlockId, args: mergeArgs));
      _finishBlock();
    }

    // Heap/weak locals declared inside a branch are scoped to that branch
    // (ADR-0023 extended this to _weakLocals, same reasoning as
    // _heapLocals) — snapshot and truncate BOTH lists around each branch.
    // `_values` gets the same snapshot/restore treatment (ADR-0027):
    // without restoring it after a branch closes, a reassignment inside it
    // would leak into a sibling branch or the fallthrough continuation,
    // referencing a DCValue that doesn't dominate their own blocks -- a
    // real, verified bug (a genuine LLVM "does not dominate all uses"
    // failure caught building that feature).
    _startBlock(thenBlockId, const []);
    final heapLocalsBeforeThen = _heapLocals.length;
    final weakLocalsBeforeThen = _weakLocals.length;
    _lowerBranchBody(stmt.then);
    final thenOpenAfter = _blockOpen &&
        !(_currentInstructions.isNotEmpty && _currentInstructions.last is DCTerminator);
    if (thenOpenAfter) {
      branchToMerge('then', heapLocalsBeforeThen, weakLocalsBeforeThen);
    } else if (_blockOpen) {
      _finishBlock(); // ends in a real terminator (return)
    }
    // else: !_blockOpen already -- nested control flow (e.g. a nested
    // if/else that itself terminated on every path) fully closed this
    // branch; nothing more to do.
    _heapLocals.removeRange(heapLocalsBeforeThen, _heapLocals.length);
    _weakLocals.removeRange(weakLocalsBeforeThen, _weakLocals.length);
    final thenReachesMerge = thenOpenAfter;
    _values
      ..clear()
      ..addAll(valuesBeforeIf);

    _startBlock(elseBlockId, const []);
    bool elseReachesMerge;
    if (otherwise != null) {
      final heapLocalsBeforeElse = _heapLocals.length;
      final weakLocalsBeforeElse = _weakLocals.length;
      _lowerBranchBody(otherwise);
      final elseOpenAfter = _blockOpen &&
          !(_currentInstructions.isNotEmpty && _currentInstructions.last is DCTerminator);
      if (elseOpenAfter) {
        branchToMerge('else', heapLocalsBeforeElse, weakLocalsBeforeElse);
      } else if (_blockOpen) {
        _finishBlock();
      }
      _heapLocals.removeRange(heapLocalsBeforeElse, _heapLocals.length);
      _weakLocals.removeRange(weakLocalsBeforeElse, _weakLocals.length);
      elseReachesMerge = elseOpenAfter;
    } else if (mergeVars.isEmpty && !thenReachesMerge) {
      // Existing guard-clause shape, unchanged: then terminates, no else,
      // no merge candidates -- elseBlockId (already open, still holding
      // valuesBeforeIf) IS the fallthrough continuation. Leave it open.
      elseReachesMerge = false;
    } else {
      // Implicit empty else that DOES need to participate in a merge
      // (either the then-branch fell through too, or it reassigned
      // something) -- its "body" is nothing, so its merge args are just
      // the unchanged pre-if values already restored into `_values` above.
      branchToMerge('else (implicit)', _heapLocals.length, _weakLocals.length);
      elseReachesMerge = true;
    }
    _values
      ..clear()
      ..addAll(valuesBeforeIf);

    if (!thenReachesMerge && !elseReachesMerge) {
      // Both branches terminated, or this is the guard-clause shape
      // (elseBlockId left open above, `_blockOpen` already reflects it
      // correctly either way) -- nothing more to do.
      return;
    }

    _startBlock(mergeBlockId, mergeParams);
    for (var i = 0; i < mergeVars.length; i++) {
      _values[mergeVars[i]] = mergeParams[i];
    }
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
  ///   - Nested loops ARE supported (ADR-0044). The carried-variable
  ///     analysis recurses into an inner loop's body, and the
  ///     `_values.containsKey` filter below keeps only variables declared
  ///     BEFORE this loop — so an inner loop's own locals are excluded while
  ///     an outer variable the inner loop assigns is correctly carried.
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
  /// (ADR-0050) `for (init; cond; update) body` -> the `while` machinery.
  ///
  ///     init;  while (cond) { body; update; }
  ///
  /// Desugared rather than given its own lowering so that loop-carried
  /// variables, nesting (ADR-0044), break/continue (ADR-0047) and heap-typed
  /// locals (ADR-0048) all apply unchanged. A second loop lowering would have
  /// meant re-deriving every one of those and getting one subtly different.
  void _lowerFor(ForStatement stmt, {LabeledStatement? breakLabel}) {
    if (stmt.condition == null) {
      throw DccLowerError(
        '"$context": `for (;;)` with no condition is not supported -- the '
        'desugaring needs a condition expression, and an always-true loop '
        'has no target that has been tested',
      );
    }
    for (final v in stmt.variables) {
      _lowerStatement(v);
    }
    _lowerWhile(
      WhileStatement(stmt.condition!, stmt.body),
      breakLabel: breakLabel,
      updates: [for (final u in stmt.updates) ExpressionStatement(u)],
    );
  }

  void _lowerWhile(
    WhileStatement stmt, {
    LabeledStatement? breakLabel,
    List<Statement> updates = const [],
  }) {
    final candidates = <VariableDeclaration>{};
    _collectLoopCarriedCandidates(stmt.body, candidates);
    // (ADR-0050) A `for` loop's update clause is where its induction variable
    // is almost always assigned -- `i = i + 1` lives there, not in the body.
    // Missing it produces a header with no phi for `i`, so the condition
    // compares the initial value forever: the same silent hang ADR-0047 hit
    // through `LabeledStatement`, reached by a different route.
    for (final u in updates) {
      _collectLoopCarriedCandidates(u, candidates);
    }

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
      // (ADR-0048) Heap-typed loop-carried variables ARE supported: a
      // reassignment inside the body retains the new value and releases the
      // old one, so the count stays balanced across every iteration, and the
      // header's phi carries whichever reference is live. That is what makes
      // `head = Node(i, head)` — building a list in a loop — expressible.
      if (current.type is! DCInt && current.type is! DCHeapPointer) {
        throw DccLowerError(
          '"$context": loop-carried variable "${v.name}" has type '
          '${current.type} — only scalar (u8/u16/u32/u64) and heap-typed '
          'locals can be reassigned inside a loop body',
        );
      }
    }

    final condBlockId = _allocBlockId();
    final bodyBlockId = _allocBlockId();
    final exitBlockId = _allocBlockId();
    // (ADR-0050) A `for` loop's update clause gets its OWN block, because
    // `continue` in a `for` must RUN the update before re-testing -- Dart
    // semantics, and the reason the update cannot simply be appended to the
    // body. `continue` targets this block; the body falls through to it; it
    // branches to the header. A `while` has no updates and this block is not
    // created, so its lowering is byte-identical to before.
    final updateBlockId = updates.isEmpty ? null : _allocBlockId();
    final continueTarget = updateBlockId ?? condBlockId;

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
    // (ADR-0047) The exit block now takes the loop variables as parameters.
    // Before `break` existed it needed none: the exit was reachable through
    // exactly one edge -- the header's false branch -- so the header's own
    // phi params still dominated it. A `break` adds a second predecessor
    // carrying DIFFERENT values (a body that assigns a loop variable then
    // breaks), and without parameters the exit would read the pre-body
    // value. That single-predecessor assumption was never written down;
    // known-gaps GAP-0037 records how it was found.
    final exitParams = [
      for (final v in loopVars) DCValue(_allocId(), _values[v]!.type),
    ];
    final condExitArgs = [for (final v in loopVars) _values[v]!];
    _addInstr(
      CondBranch(cond: cond, trueTarget: bodyBlockId, trueArgs: const [], falseTarget: exitBlockId, falseArgs: condExitArgs),
    );
    _finishBlock();

    // Register both label kinds before lowering the body, since a `break` or
    // `continue` inside it resolves through this map.
    if (breakLabel != null) {
      _labelTargets[breakLabel] = (target: exitBlockId, vars: loopVars);
    }
    final body = stmt.body;
    if (body is LabeledStatement) {
      // A label wrapping the loop BODY is `continue`: branch to the header,
      // which is exactly what the back edge below does.
      _labelTargets[body] = (target: continueTarget, vars: loopVars);
    }

    _startBlock(bodyBlockId, const []);
    final heapLocalsBeforeBody = _heapLocals.length;
    final weakLocalsBeforeBody = _weakLocals.length;
    // Unwrap the continue-label if present: it was registered above, and
    // what actually needs lowering is the statement inside it.
    _lowerBranchBody(body is LabeledStatement ? body.body : body);
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
      _addInstr(Branch(target: continueTarget, args: backArgs));
      _finishBlock();
    }

    // The update block: lower the update expressions, then close the loop.
    // Its parameters carry the loop variables in, because `continue` may
    // branch here from anywhere in the body with different values.
    if (updateBlockId != null) {
      final updateParams = [
        for (final v in loopVars) DCValue(_allocId(), _values[v]!.type),
      ];
      _startBlock(updateBlockId, updateParams);
      for (var i = 0; i < loopVars.length; i++) {
        _values[loopVars[i]] = updateParams[i];
      }
      for (final u in updates) {
        _lowerStatement(u);
      }
      if (_blockOpen) {
        _addInstr(Branch(
          target: condBlockId,
          args: [for (final v in loopVars) _values[v]!],
        ));
        _finishBlock();
      }
    }

    // (ADR-0047) What's live after the loop is the EXIT block's own
    // parameters, not the header's. The header's params were correct while
    // the exit had a single predecessor; now that a `break` can reach it
    // with different values, only a real phi at the exit is right.
    _startBlock(exitBlockId, exitParams);
    for (var i = 0; i < loopVars.length; i++) {
      _values[loopVars[i]] = exitParams[i];
    }
  }

  /// Pure Kernel-IR-AST walk collecting every `VariableSet` target
  /// reachable inside `stmt` (recursing into `Block` and `IfStatement`'s
  /// arms) — used by `_lowerWhile` to find candidate loop-carried variables
  /// BEFORE actually lowering the body (the header block's phi params must
  /// exist before the body that reads/writes them does), AND by `_lowerIf`
  /// (ADR-0032) to find candidate if/else-merge variables before lowering
  /// either branch, for the identical reason. Throws on a nested loop
  /// rather than silently scoping the analysis to the wrong loop — nested
  /// loops (and composing a loop's own header merge with an if/else merge
  /// in the same pass) are real, separate, unimplemented work.
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
    if (stmt is ForStatement) {
      // (ADR-0050) A nested `for` inside a loop body: collect from its body
      // AND its updates, since `i = i + 1` in the update clause is exactly a
      // loop-carried assignment.
      _collectLoopCarriedCandidates(stmt.body, out);
      for (final u in stmt.updates) {
        if (u is VariableSet) out.add(u.variable);
      }
      return;
    }
    if (stmt is LabeledStatement) {
      // (ADR-0047) A `continue` wraps the loop BODY in a LabeledStatement.
      // Missing this case is what produced the silent hang described below.
      _collectLoopCarriedCandidates(stmt.body, out);
      return;
    }
    if (stmt is WhileStatement) {
      // (ADR-0044) Recurse into a nested loop's body rather than refusing.
      //
      // The original refusal worried about "silently scoping the analysis to
      // the wrong loop". That concern is already handled one level up:
      // `_lowerWhile` keeps only candidates already present in `_values`,
      // i.e. declared BEFORE this loop began. A variable declared inside the
      // inner body is not in `_values` when the OUTER header is built, so it
      // is excluded automatically — while a variable declared outside and
      // assigned by the inner loop genuinely IS carried by the outer loop
      // and must be collected here.
      _collectLoopCarriedCandidates(stmt.body, out);
      return;
    }
    // ANYTHING ELSE IS A HARD ERROR, and that is the point (ADR-0047).
    //
    // This used to fall off the end silently, on the reasoning that anything
    // unrecognized "can't itself carry a VariableSet target". That reasoning
    // was wrong in exactly one way and it cost a silent miscompilation:
    // `LabeledStatement` — which is how `continue` arrives — wraps the ENTIRE
    // loop body, so falling through here collected NOTHING. The header got no
    // phi parameters, the condition compared the variable's entry value
    // forever, and the emitted loop branched to itself. No diagnostic, no
    // wrong answer: a hang.
    //
    // A missed assignment cannot be reported later either, because there is
    // nothing malformed downstream to report — the IR is well-formed and just
    // means something else. So the walk must be exhaustive, and the
    // statements below are listed because they genuinely cannot contain a
    // loop-carried assignment, not because they were the ones that happened
    // to show up.
    if (stmt is ReturnStatement ||
        stmt is BreakStatement ||
        stmt is EmptyStatement ||
        stmt is VariableDeclaration ||
        stmt is ExpressionStatement) {
      return;
    }
    throw DccLowerError(
      '"$context": loop-carried-variable analysis met an unhandled statement '
      '${stmt.runtimeType} inside a loop body. Refusing rather than skipping '
      'it: a missed assignment emits a loop whose header never updates that '
      'variable, which is a silent hang rather than an error '
      '(docs/decisions/0047-break-and-continue.md).',
    );
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

          // The DEST type is not always the operand width: a comparison
          // consumes two ints and produces a DCBool. Getting this wrong is
          // silent -- the ICmp would be emitted with an integer dest type
          // and `llvm_emit` would print `icmp` into an iN slot -- so the
          // dest type is chosen per-op here, alongside the instruction,
          // rather than defaulted from `widthType` (ADR-0035).
          //
          // DCBool is assigned DIRECTLY, never read from front_end's
          // inferred `bool` type: under --no-link-platform that type is a
          // real but unbound platform node that crashes on inspection.
          // Same discipline ADR-0014 established for Result.
          final destType = switch (op) {
            '&' || '|' || '^' || '<<' || '>>' => widthType,
            '+' || '-' || '*' || '~/' || '%' => widthType,
            '<' || '<=' || '>' || '>=' => const DCBool(),
            _ => null,
          };

          // Every sized-int type the prelude exposes is UNSIGNED (spec
          // §4.1's signed i8..i64 have no prelude support yet), so the
          // unsigned predicates are the correct choice. `llvm_emit` prints
          // `predicate.name` verbatim and derives NO signedness of its own,
          // so a signed type landing here later must select the `s`-prefixed
          // predicates at THIS site, not downstream.
          final emit = switch (op) {
            '&' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IAnd(dest: dest, lhs: lhs, rhs: rhs)),
            '|' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IOr(dest: dest, lhs: lhs, rhs: rhs)),
            '^' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IXor(dest: dest, lhs: lhs, rhs: rhs)),
            '<<' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IShl(dest: dest, lhs: lhs, rhs: rhs)),
            '>>' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IShr(dest: dest, lhs: lhs, rhs: rhs)),
            // Arithmetic traps on overflow (spec §4.1). `*` needed no new
            // DC-IR node or backend work: IMul has existed with real
            // codegen since M0 and simply had no operator wired to it.
            '+' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IAdd(dest: dest, lhs: lhs, rhs: rhs, overflow: Overflow.trapping)),
            '-' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(ISub(dest: dest, lhs: lhs, rhs: rhs, overflow: Overflow.trapping)),
            '*' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IMul(dest: dest, lhs: lhs, rhs: rhs, overflow: Overflow.trapping)),
            // `~/` and `%` carry no Overflow flag -- their failure mode is a
            // zero divisor, trapped explicitly in the backend (ADR-0036).
            '~/' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IDiv(dest: dest, lhs: lhs, rhs: rhs)),
            '%' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(IRem(dest: dest, lhs: lhs, rhs: rhs)),
            '<' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(ICmp(dest: dest, predicate: ICmpPredicate.ult, lhs: lhs, rhs: rhs)),
            '<=' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(ICmp(dest: dest, predicate: ICmpPredicate.ule, lhs: lhs, rhs: rhs)),
            '>' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(ICmp(dest: dest, predicate: ICmpPredicate.ugt, lhs: lhs, rhs: rhs)),
            '>=' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(ICmp(dest: dest, predicate: ICmpPredicate.uge, lhs: lhs, rhs: rhs)),
            _ => null,
          };
          if (widthType != null && emit != null && destType != null) {
            return _lowerU64Binary(expr, emit, destType);
          }

          // Explicit width conversions (`.toU8()`/`.toU16()`/`.toU32()`/
          // `.toU64()`, spec §4.1, ADR-0037). UNARY, unlike every operator
          // above: an extension-type method call passes only the receiver
          // positionally, so this cannot go through `_lowerU64Binary`.
          final convertTo = switch (op) {
            'toU8' => DCInt.u8,
            'toU16' => DCInt.u16,
            'toU32' => DCInt.u32,
            'toU64' => DCInt.u64,
            _ => null,
          };
          if (widthType != null && convertTo != null) {
            final args = expr.arguments.positional;
            if (args.length != 1) {
              throw DccLowerError(
                '"$context": ${target.name.text} with ${args.length} '
                'arguments, expected 1 (the receiver)',
              );
            }
            final source = _lowerExpression(args.single);
            final dest = DCValue(_allocId(), convertTo);
            _addInstr(IConvert(dest: dest, source: source));
            return dest;
          }
        }
      }

      // `Rodata.addressOf(table)` (ADR-0040) -- a plain static method call,
      // recognized the same way `Port.inb` is: static + enclosing class name
      // + prelude URI. Its argument must be a StaticGet naming a @rodata
      // field; anything else cannot have an address.
      if (target.isStatic &&
          target.name.text == 'addressOf' &&
          target.enclosingClass?.name == 'Rodata' &&
          target.enclosingLibrary.importUri == preludeUri) {
        final args = expr.arguments.positional;
        if (args.length != 1) {
          throw DccLowerError(
            '"$context": Rodata.addressOf takes exactly one argument',
          );
        }
        final arg = args.single;
        if (arg is! StaticGet || arg.target is! Field) {
          throw DccLowerError(
            '"$context": Rodata.addressOf needs the NAME of a `@rodata` '
            'table, got ${arg.runtimeType}. It cannot take an expression — '
            'the address has to be resolvable to a symbol at compile time.',
          );
        }
        final name = arg.target.name.text;
        if (!globalNames.contains(name)) {
          throw DccLowerError(
            '"$context": "$name" is not a `@rodata` table in this '
            'compilation unit, so it has no static address. Declare it '
            '`@rodata final List<uN> $name = const [...]`.',
          );
        }
        final dest = DCValue(_allocId(), DCInt.u64);
        _addInstr(AddressOfGlobal(dest: dest, globalName: name));
        return dest;
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
          // A named `const int` is NOT an IntLiteral by the time it reaches
          // us: the CFE has already evaluated it and replaced the reference
          // with a `ConstantExpression` wrapping an `IntConstant`. Both
          // spellings mean the same compile-time integer, so both are
          // accepted -- otherwise `const stride = 4;` is rejected while a
          // bare `4` works, which is a confusing distinction with no
          // reason behind it (found by writing examples/demo-stats, ADR-0037).
          final folded = _tryFoldConstInt(arg);
          final int bits;
          if (folded != null) {
            bits = folded;
          } else {
            throw DccLowerError(
              '"$context": a $sizedIntType literal constructed from a '
              'non-constant expression $arg (${arg.runtimeType}) — the '
              'argument must be an integer literal or a compile-time '
              'integer constant',
            );
          }
          final dest = DCValue(_allocId(), sizedIntType);
          _addInstr(ConstInt(dest: dest, bits: bits));
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
          (target.name.text == 'inb' ||
              target.name.text == 'inw' ||
              target.name.text == 'inl') &&
          target.enclosingLibrary.importUri == preludeUri) {
        final port = _lowerExpression(expr.arguments.positional.single);
        if (port.type != DCInt.u16) {
          throw DccLowerError(
            '"$context": Port.inb\'s port argument has type ${port.type}, '
            'expected u16',
          );
        }
        // Result width follows the mnemonic (ADR-0045). PCI config space is
        // decoded for doublewords only, which is why `inl` exists at all.
        final resultType = switch (target.name.text) {
          'inw' => DCInt.u16,
          'inl' => DCInt.u32,
          _ => DCInt.u8,
        };
        final dest = DCValue(_allocId(), resultType);
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

      // (ADR-0038) A call to an `@extern` C-ABI symbol. Recognized in the
      // same last position and lowered through the SAME `Call` instruction
      // as the `@bare` case above — the two are indistinguishable at the
      // call site by design (see DCExternFunction's doc comment); the only
      // difference is that the backend emits a `declare` instead of a
      // `define` for the callee.
      if (_hasMarkerAnnotation(target.annotations, '_Extern', preludeUri)) {
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
        // `Pointer<T>.value` read -- volatile for the same reason as the
        // store above. Without this, `-O2` deletes a register read-back
        // entirely (ADR-0041, GAP-0006).
        _addInstr(Load(dest: dest, pointer: pointer, isVolatile: true));
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

      // (ADR-0043) `receiver.method(args)` on a HeapObject subclass -> a
      // direct Call with the receiver as argument 0. No dispatch: the
      // concrete class is statically known at every call site, exactly as
      // ADR-0022 established for destructors.
      final enclosing = target.enclosingClass;
      if (!target.isStatic &&
          target.kind == ProcedureKind.Method &&
          enclosing != null &&
          heapLayouts.extendsHeapObject(enclosing)) {
        final receiver = _lowerExpression(expr.receiver);
        final args = <DCValue>[receiver];
        for (final arg in expr.arguments.positional) {
          args.add(_lowerExpression(arg));
        }
        final returnType = _lowerType(
          target.function.returnType,
          context: '$context call to ${target.name.text}',
        );
        final dest = DCValue(_allocId(), returnType);
        _addInstr(Call(
          dest: dest,
          targetName: methodLinkName(enclosing.name, target.name.text),
          args: args,
          // The receiver is BORROWED (ADR-0019's default): the caller keeps
          // its reference for the duration of the call, so the callee must
          // not release it. Same convention as any non-@owned heap param.
          argOwnership: List<bool>.filled(args.length, false),
        ));
        return dest;
      }

      if (target.name.text == 'propagate' &&
          target.enclosingClass?.name == 'Result' &&
          target.enclosingLibrary.importUri == preludeUri) {
        return _lowerPropagate(expr);
      }
    }

    // (ADR-0049) `null` as a heap reference.
    if (expr is NullLiteral) {
      final dest = DCValue(_allocId(), const DCHeapPointer(DCVoid()));
      _addInstr(NullRef(dest: dest));
      return dest;
    }

    // (ADR-0049) `x == null` / `x != null`. Kernel gives these their OWN node
    // -- `EqualsNull`, not the `EqualsCall` that ADR-0035 handles for sized
    // ints -- so this is a separate case rather than a wider type check on
    // the existing one. `!= null` arrives as `Not(EqualsNull)`.
    if (expr is EqualsNull) {
      return _lowerNullCheck(expr.expression, negated: false);
    }

    // (ADR-0043) `this` inside an instance method is param 0.
    if (expr is ThisExpression) {
      final self = _thisValue;
      if (self == null) {
        throw DccLowerError(
          '"$context": `this` used outside an instance method',
        );
      }
      return self;
    }

    // `@rodata` table address (ADR-0040). A `StaticGet` reaches here ONLY
    // for a non-const field -- a `const` field's references are inlined by
    // the frontend and never appear as a StaticGet at all, which is exactly
    // why `@rodata` requires `final`.
    if (expr is StaticGet) {
      final target = expr.target;
      final name = target.name.text;
      if (target is Field && globalNames.contains(name)) {
        throw DccLowerError(
          '"$context": a `@rodata` table cannot be read directly as a value '
          '-- it is static data, not a Dart list. Take its address with '
          '`Rodata.addressOf($name)` and read through a `Pointer<T>`.',
        );
      }
      throw DccLowerError(
        '"$context": unsupported static read of "$name". Only `@rodata` '
        'globals have a static-data representation (ADR-0040); ordinary '
        'top-level variables are not implemented.',
      );
    }

    // `a == b` and `a != b` on sized ints (ADR-0035).
    //
    // These CANNOT go through the `"<width>|<op>"` StaticInvocation path
    // every other operator uses, because Dart refuses to let an extension
    // type declare `operator ==` at all ("This extension member conflicts
    // with Object member '=='"). So there is no `u64|==` procedure for the
    // prelude to declare or for lowering to match on. Instead the CFE emits
    // a distinct node: `a == b` becomes an `EqualsCall` bound to
    // `dart:core::Object::==`, and `a != b` becomes `Not(EqualsCall)`.
    //
    // Matching on the LOWERED operand types rather than on front_end's
    // inferred static types is deliberate, and follows ADR-0014's rule: an
    // inferred `bool`/`Object` type here is a real but unbound platform
    // node under `--no-link-platform` and crashes on inspection. The DC-IR
    // values we just produced carry the width we actually need.
    if (expr is EqualsCall) {
      return _lowerIntEquality(expr, negated: false);
    }
    if (expr is Not) {
      final operand = expr.operand;
      if (operand is EqualsCall) {
        return _lowerIntEquality(operand, negated: true);
      }
      if (operand is EqualsNull) {
        return _lowerNullCheck(operand.expression, negated: true);
      }
      // A general boolean `!` needs a NOT on an i1, which DC-IR has no
      // instruction for. `!=` is handled above as a single `icmp ne` rather
      // than "compare then invert", so nothing needs it yet; a real `!`
      // operator is left unimplemented instead of faked (GAP-0023).
      throw DccLowerError(
        '"$context": `!` is only supported as part of `!=` on sized ints; '
        'a general boolean NOT has no DC-IR instruction yet (GAP-0023)',
      );
    }

    throw DccLowerError(
      '"$context": unsupported expression $expr (${expr.runtimeType}) — see '
      'core/dcc-lower/README.md for exactly what is handled',
    );
  }

  /// `x == null` / `x != null` on a heap reference (ADR-0049).
  ///
  /// Compared as pointers, which is the only comparison a heap reference
  /// supports: there is no structural equality and no `operator ==` to call.
  DCValue _lowerNullCheck(Expression operand, {required bool negated}) {
    final value = _lowerExpression(operand);
    if (value.type is! DCHeapPointer) {
      throw DccLowerError(
        '"$context": comparing ${value.type} against null. Only heap '
        'references can be null.',
      );
    }
    final nullValue = DCValue(_allocId(), value.type);
    _addInstr(NullRef(dest: nullValue));
    final dest = DCValue(_allocId(), const DCBool());
    _addInstr(ICmp(
      dest: dest,
      predicate: negated ? ICmpPredicate.ne : ICmpPredicate.eq,
      lhs: value,
      rhs: nullValue,
    ));
    return dest;
  }

  /// `a == b` / `a != b` where both sides are the same sized-int type.
  ///
  /// Rejects mismatched widths rather than inserting an implicit
  /// extension/truncation: DCDart has no implicit integer conversions
  /// (spec §4.1), and silently widening one side here would be exactly the
  /// kind of invisible conversion the sized-int model exists to prevent.
  DCValue _lowerIntEquality(EqualsCall expr, {required bool negated}) {
    final lhs = _lowerExpression(expr.left);
    final rhs = _lowerExpression(expr.right);
    final lhsType = lhs.type;
    final rhsType = rhs.type;
    if (lhsType is! DCInt || rhsType is! DCInt) {
      throw DccLowerError(
        '"$context": ${negated ? '!=' : '=='} is only supported between two '
        'sized integers, got $lhsType and $rhsType',
      );
    }
    if (lhsType.width != rhsType.width || lhsType.signed != rhsType.signed) {
      throw DccLowerError(
        '"$context": ${negated ? '!=' : '=='} between different integer '
        'types ($lhsType vs $rhsType). DCDart has no implicit integer '
        'conversions — convert one side explicitly.',
      );
    }
    final dest = DCValue(_allocId(), const DCBool());
    _addInstr(ICmp(
      dest: dest,
      predicate: negated ? ICmpPredicate.ne : ICmpPredicate.eq,
      lhs: lhs,
      rhs: rhs,
    ));
    return dest;
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
  /// under-counting it.
  ///
  /// (ADR-0038) Also lowers a call to an `@extern` C-ABI symbol — the same
  /// `Call` instruction, deliberately: the two are identical at the call
  /// site and differ only in whether the backend emits a `define` or a
  /// `declare` for the callee.
  DCValue _lowerBareCall(StaticInvocation expr, Procedure target) {
    final result = _lowerCallTo(expr, target, allowVoid: false);
    if (result == null) {
      throw DccLowerError(
        '"$context": internal error — _lowerCallTo returned no value with '
        'allowVoid: false (dcc-lower bug, not a source error)',
      );
    }
    return result;
  }

  /// The call-lowering body shared by expression and statement context.
  /// Returns `null` exactly when the callee returns void, which is only
  /// reachable with [allowVoid] set — `_lowerExpression` has a non-nullable
  /// return type and cannot represent "no value" (ADR-0018 recorded this;
  /// ADR-0038 is where a real target — a `void` C function — finally needed
  /// the statement side of it, closing the other half of the gap ADR-0029
  /// opened for `Port.outb` alone).
  DCValue? _lowerCallTo(
    StaticInvocation expr,
    Procedure target, {
    required bool allowVoid,
  }) {
    final calleeFn = target.function;
    final returnType = calleeFn.returnType;
    final isExtern = _hasMarkerAnnotation(target.annotations, '_Extern', preludeUri);
    if (isExtern && !externNames.contains(target.name.text)) {
      // See `externNames`'s doc comment: an `@extern` resolved from another
      // library was never collected here, so it has no `declare` and is not
      // in the manifest verify-freestanding.sh reads.
      throw DccLowerError(
        '"$context": call to `@extern` symbol "${target.name.text}", which is '
        'declared in ${target.enclosingLibrary.importUri}, not in this '
        'compilation unit — declare it in this file so the symbol is recorded '
        'in this object\'s extern manifest '
        '(docs/decisions/0038-extern-symbols-and-linking.md)',
      );
    }
    if (returnType is VoidType) {
      if (!allowVoid) {
        throw DccLowerError(
          '"$context": call to "${target.name.text}", which returns void -- '
          'a void call has no value, so it can only appear as a statement '
          'on its own line, not inside an expression',
        );
      }
      _lowerCallArgs(expr, target, dest: null);
      return null;
    }
    final calleeReturnType = _lowerType(
      returnType,
      context: '"${target.name.text}" return type (called from "$context")',
    );

    final dest = DCValue(_allocId(), calleeReturnType);
    _lowerCallArgs(expr, target, dest: dest);
    return dest;
  }

  /// Lowers a call's arguments and emits the `Call`. Split out of
  /// [_lowerCallTo] (ADR-0038) so the void case — which has no `dest` to
  /// allocate — runs the identical argument path instead of a second copy of
  /// it.
  void _lowerCallArgs(
    StaticInvocation expr,
    Procedure target, {
    required DCValue? dest,
  }) {
    final calleeFn = target.function;
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

    _addInstr(Call(dest: dest, targetName: target.name.text, args: loweredArgs, argOwnership: argOwnership));
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

  /// `heapInstance.field = value` -> `PtrOffset` + `Store` (ADR-0032),
  /// mirroring `_lowerHeapFieldLoad`'s addressing exactly, just in the
  /// Store direction -- a real gap `_lowerHeapFieldLoad` existed but this
  /// never did, only found by writing an actual program (`sumCollatzSteps`
  /// mutating an accumulator field in a loop, `core/examples/demo-collatz`).
  /// Scalar (`DCInt`) fields only: a heap- or weak-typed field STORE
  /// raises the exact same real ownership question ADR-0027 already
  /// flagged for local reassignment (does overwriting release the old
  /// value? retain the new one?) -- undecided, so it throws a clear error
  /// rather than guessing at a policy nobody has designed yet.
  void _lowerHeapFieldStore(InstanceSet expr, Class heapClass) {
    final field = _findHeapField(heapClass, expr.interfaceTarget.name.text);
    if (field.type is DCWeakPointer) {
      throw DccLowerError(
        '"$context": storing to the weak field '
        '"${heapClass.name}.${field.name}" is not supported. The strong-field '
        'policy (ADR-0048) does not transfer: a weak store must adjust the '
        'WEAK count and interacts with the zombie-slot semantics of ADR-0023, '
        'which is a separate decision nobody has made.',
      );
    }
    final objectPtr = _lowerExpression(expr.receiver);
    final fieldPtr = DCValue(_allocId(), DCPointer(field.type));
    _addInstr(PtrOffset(dest: fieldPtr, base: objectPtr, offsetBytes: field.offset));
    final value = _lowerExpression(expr.value);
    if (value.type != field.type) {
      throw DccLowerError(
        '"$context": assigning a value of type ${value.type} to '
        '"${heapClass.name}.${field.name}", declared ${field.type} -- no '
        'implicit widening (same rule as arithmetic)',
      );
    }

    // (ADR-0048) A STRONG heap-typed field store is an ownership transfer.
    // Three operations, and the ORDER is load-bearing:
    //
    //   1. retain the new value  (unless it is already a fresh +1)
    //   2. load the old value
    //   3. store the new value
    //   4. release the old value
    //
    // Retain-before-release, never the reverse: `a.next = a.next` would
    // otherwise release the object between the two steps and store a
    // dangling pointer. The retain is skipped when the right-hand side is a
    // fresh-ownership source (`a.next = Node(...)`), because `Alloc` already
    // produced the +1 this store is taking over -- the same rule ADR-0021
    // applies to an `@owned` parameter, reusing the same predicate.
    if (field.type is DCHeapPointer) {
      if (!_isFreshHeapOwnership(expr.value)) {
        _addInstr(Retain(object: value));
      }
      final oldValue = DCValue(_allocId(), field.type);
      _addInstr(Load(dest: oldValue, pointer: fieldPtr));
      _addInstr(Store(pointer: fieldPtr, value: value));
      _addInstr(Release(object: oldValue));
      return;
    }

    _addInstr(Store(pointer: fieldPtr, value: value));
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

  /// Thin delegate to the shared [_lowerSignatureType]. Extracted (ADR-0038)
  /// so extern DECLARATIONS — which have no `_BareFunctionLowerer` at all,
  /// being collected at module scope before any function is lowered — map
  /// their parameter and return types through the exact same code path a
  /// defined function's signature does, rather than a second, drifting copy.
  DCType _lowerType(DartType type, {required String context}) =>
      _lowerSignatureType(type, preludeUri: preludeUri, heapLayouts: heapLayouts, context: context);
}

DCType _lowerSignatureType(
  DartType type, {
  required Uri preludeUri,
  required _HeapLayouts heapLayouts,
  required String context,
}) {
  if (true) {
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

/// Throws if any library OTHER than [targetLibrary] declares a `@bare`
/// function, because `lowerToDCModule` only lowers `targetLibrary` and those
/// functions would otherwise be dropped without a word.
///
/// Deliberately NOT a warning. The failure this replaces was a successful
/// build with a missing symbol, which surfaces either as an unreadable
/// `use of undefined value '@f'` from clang (if something calls it) or as
/// nothing at all until a C caller fails to link (if nothing does). Both are
/// worse than refusing to build.
void _rejectBareFunctionsInImportedLibraries(
  Component component, {
  required Library targetLibrary,
  required Uri preludeUri,
}) {
  final dropped = <String>[];
  for (final library in component.libraries) {
    if (identical(library, targetLibrary)) continue;
    // The prelude declares no `@bare` functions (its members are extension
    // types and marker classes), and `dart:` libraries are never ours.
    if (library.importUri == preludeUri) continue;
    if (library.importUri.scheme == 'dart') continue;
    for (final proc in library.procedures) {
      if (_hasMarkerAnnotation(proc.annotations, '_Bare', preludeUri)) {
        dropped.add('${proc.name.text}  (${library.importUri})');
      }
    }
  }
  if (dropped.isEmpty) return;

  throw DccLowerError(
    'these `@bare` functions are declared in imported libraries and would be '
    'silently dropped from the output object:\n'
    '  ${dropped.join('\n  ')}\n'
    'dcc compiles ONE library per object file — only `${targetLibrary.importUri}` '
    'is lowered, and anything `@bare` in a library it imports is not compiled '
    'at all (docs/known-gaps.md GAP-0028). Until multi-library compilation '
    'exists, put every `@bare` function in the file being compiled, or pull '
    'the others in with `part`/`part of` so they share one library.',
  );
}

/// Builds a struct global from a const class instance (ADR-0040).
///
/// Field WIDTHS come from the class's declared field types, not from the
/// values: an `InstanceConstant`'s field values are bare `IntConstant`s with
/// every sized-int extension type erased, exactly as list elements are. The
/// class node is safe to inspect here — unlike `dart:core`'s `List`, a class
/// declared in the file being compiled is fully bound.
///
/// Field ORDER follows the class's declaration order rather than the
/// constant's map iteration order, because that order IS the emitted layout
/// and a consumer walks it by offset.
DCGlobal _rodataStructGlobal(
  InstanceConstant constant,
  String name,
  Uri preludeUri,
) {
  final cls = constant.classNode;
  final fields = <DCConstant>[];
  var maxAlign = 1;

  for (final classField in cls.fields) {
    if (classField.isStatic) continue;
    final value = constant.fieldValues[classField.fieldReference];
    if (value == null) {
      throw DccLowerError(
        '"$name": field "${classField.name.text}" of ${cls.name} has no '
        'constant value',
      );
    }

    final declared = classField.type;
    if (declared is InterfaceType &&
        declared.classReference.canonicalName?.name == 'Ref') {
      if (value is! InstanceConstant) {
        throw DccLowerError(
          '"$name": field "${classField.name.text}" is a Ref but its value is '
          'a ${value.runtimeType}',
        );
      }
      final values = value.fieldValues.values.toList();
      final symbol = values.length == 1 ? values.single : null;
      if (symbol is! StringConstant) {
        throw DccLowerError(
          '"$name": Ref must hold a single constant string naming another '
          '`@rodata` declaration',
        );
      }
      fields.add(DCConstAddrOf(symbol.value));
      maxAlign = maxAlign < 8 ? 8 : maxAlign;
      continue;
    }

    final width = _sizedIntOf(declared);
    if (width == null) {
      throw DccLowerError(
        '"$name": field "${classField.name.text}" has type $declared. A '
        '`@rodata` record\'s fields must be sized integers (u8/u16/u32/u64) '
        'or `Ref`. A bare `int` is rejected for the same reason `List<int>` '
        'is: the constant erases the width, so the declared type is the only '
        'thing that can decide the layout.',
      );
    }
    if (value is! IntConstant) {
      throw DccLowerError(
        '"$name": field "${classField.name.text}" is declared $declared but '
        'its constant is a ${value.runtimeType}',
      );
    }
    fields.add(DCConstInt(width, value.value));
    final w = _byteWidthOfInt(width);
    if (w > maxAlign) maxAlign = w;
  }

  if (fields.isEmpty) {
    throw DccLowerError(
      '"$name": ${cls.name} has no instance fields, so there is nothing to '
      'emit. An empty record is not a useful global.',
    );
  }

  return DCGlobal(
    linkName: name,
    initializer: DCConstStruct(fields),
    // A struct's alignment is its widest field's, matching what C would do
    // for the same fields.
    alignBytes: maxAlign,
  );
}

/// The `DCInt` a declared sized-int type maps to, or null if it is not one.
DCInt? _sizedIntOf(DartType declared) {
  if (declared is ExtensionType) {
    switch (declared.extensionTypeDeclaration.name) {
      case 'u8':
        return DCInt.u8;
      case 'u16':
        return DCInt.u16;
      case 'u32':
        return DCInt.u32;
      case 'u64':
        return DCInt.u64;
    }
  }
  return null;
}

/// Walks a constant tree and rejects any [DCConstAddrOf] naming something
/// that is not a `@rodata` global in this compilation unit.
void _checkRelocationTargets(
  DCConstant constant,
  String owner,
  Set<String> knownGlobals,
) {
  switch (constant) {
    case DCConstInt():
      return;
    case DCConstArray(elements: final elements):
      for (final element in elements) {
        _checkRelocationTargets(element, owner, knownGlobals);
      }
    case DCConstStruct(fields: final fields):
      for (final field in fields) {
        _checkRelocationTargets(field, owner, knownGlobals);
      }
    case DCConstAddrOf(globalName: final target):
      if (!knownGlobals.contains(target)) {
        throw DccLowerError(
          '"$owner" contains Ref(\'$target\'), but "$target" is not a '
          '`@rodata` table in this compilation unit. Cross-object references '
          'would need address-of-extern, which does not exist '
          '(docs/known-gaps.md GAP-0019).',
        );
      }
  }
}

/// Evaluates a compile-time integer expression, or returns null if it is not
/// one (ADR-0046).
///
/// Handles the three shapes a constant integer actually arrives in:
///
///   `4`                  IntLiteral
///   `someConstInt`       ConstantExpression(IntConstant) -- the CFE has
///                        already inlined and evaluated it
///   `someConstInt - 1`   InstanceInvocation -- NOT pre-folded, because an
///                        argument position is not a const context
///
/// The third is why this exists. `u64(first - 1)` used to be rejected with
/// "the argument must be an integer literal or a compile-time integer
/// constant" while being exactly that: the check pattern-matched node shapes
/// and never evaluated anything, so its own error message described a rule it
/// did not implement (known-gaps GAP-0037).
///
/// Reads `expr.name.text` rather than `interfaceTarget`. The operator belongs
/// to `dart:core`'s `int`, an unbound reference under `--no-link-platform`
/// that throws on inspection; the invoked NAME is a plain `Name` on the node
/// itself and is always safe. Same unbound-platform-node trap ADR-0014 and
/// ADR-0040 both hit.
///
/// Deliberately NOT a general constant evaluator: integer arithmetic on
/// operands that are themselves foldable, and nothing else. Division by zero
/// returns null (treated as non-constant) rather than throwing -- a
/// compile-time division by zero deserves a diagnostic of its own, not a
/// crash inside the folder.
int? _tryFoldConstInt(Expression expr) {
  if (expr is IntLiteral) return expr.value;
  if (expr is ConstantExpression) {
    final constant = expr.constant;
    return constant is IntConstant ? constant.value : null;
  }
  if (expr is InstanceInvocation) {
    final args = expr.arguments.positional;
    if (args.length != 1) return null;
    final lhs = _tryFoldConstInt(expr.receiver);
    final rhs = _tryFoldConstInt(args.single);
    if (lhs == null || rhs == null) return null;
    switch (expr.name.text) {
      case '+':
        return lhs + rhs;
      case '-':
        return lhs - rhs;
      case '*':
        return lhs * rhs;
      case '~/':
        return rhs == 0 ? null : lhs ~/ rhs;
      case '%':
        return rhs == 0 ? null : lhs % rhs;
      case '<<':
        return (rhs < 0 || rhs > 63) ? null : lhs << rhs;
      case '>>':
        return (rhs < 0 || rhs > 63) ? null : lhs >> rhs;
      case '&':
        return lhs & rhs;
      case '|':
        return lhs | rhs;
      case '^':
        return lhs ^ rhs;
      default:
        return null;
    }
  }
  return null;
}

/// The emitted symbol name for an instance method (ADR-0043).
///
/// `Class_method`, not the Dart name alone, because two classes may declare
/// the same method name and `linkName` goes out verbatim (spec §9) with no
/// mangling anywhere downstream. Deliberately simple and readable rather
/// than a mangling scheme — a C caller can name it, and there is no
/// overloading in DCDart for a scheme to disambiguate.
String methodLinkName(String className, String methodName) =>
    '${className}_$methodName';

/// Collects every `@rodata` field in [library] as a [DCGlobal] (ADR-0040).
///
/// REQUIRES `final` with an explicitly `const` initializer, and rejects
/// everything else by name. The near-miss spellings are the reason:
///
///   `@rodata const List<u64> t = [...]`  -- a `const` FIELD. Its references
///       are inlined by the frontend, so no use site can ever name it, and
///       two identical declarations are canonicalized to one object. It
///       would emit a global nothing could address.
///   `@rodata final List<u64> t = [...]`  -- no `const` on the initializer.
///       Degrades to `StaticInvocation(_GrowableList._literal3(...))`, a
///       dart:core factory that is unbound under `--no-link-platform` and
///       carries no Constant at all. Looks almost identical to the correct
///       spelling.
///
/// Both are rejected loudly rather than half-handled, per GAP-0028's rule
/// that a silent drop is worse than a compile error.
List<DCGlobal> _collectRodataGlobals(
  Library library, {
  required Uri preludeUri,
}) {
  final globals = <DCGlobal>[];
  for (final field in library.fields) {
    if (!_hasMarkerAnnotation(field.annotations, '_Rodata', preludeUri)) {
      continue;
    }
    final name = field.name.text;

    if (field.isConst) {
      throw DccLowerError(
        '"$name" is `@rodata const`. Use `final` with a `const` initializer '
        'instead: `@rodata final List<u64> $name = const [...]`. A `const` '
        'field is inlined at every use site, so nothing could take its '
        'address, and identical constants are canonicalized into one object '
        '(docs/decisions/0040-static-rodata.md).',
      );
    }
    if (!field.isFinal) {
      throw DccLowerError(
        '"$name" is `@rodata` but not `final`. Static data has no '
        'initializer machinery to run, so it must be `final` with a `const` '
        'initializer.',
      );
    }

    final initializer = field.initializer;
    if (initializer is! ConstantExpression) {
      throw DccLowerError(
        '"$name" is `@rodata final` but its initializer is not a compile-time '
        'constant (got ${initializer.runtimeType}). Write the initializer as '
        '`const [...]` — without the `const` keyword a list literal becomes a '
        'runtime-allocated list, which cannot be emitted as static data.',
      );
    }

    final constant = initializer.constant;

    // A const class instance is a STRUCT global -- the descriptor shape,
    // `{ ptr name, u32 count, ptr fields }`, which cannot be an array
    // because an LLVM array is homogeneous (ADR-0040, GAP-0031).
    if (constant is InstanceConstant) {
      globals.add(_rodataStructGlobal(constant, name, preludeUri));
      continue;
    }

    final elementType = _rodataElementType(field.type, name);
    if (constant is! ListConstant) {
      throw DccLowerError(
        '"$name" is `@rodata` but its constant is a '
        '${constant.runtimeType}. Supported shapes are a `List<uN>` table, a '
        '`List<Ref>` address table, or a const class instance (a record).',
      );
    }

    final isRelocationTable = elementType == null;
    final elements = <DCConstant>[];
    for (final entry in constant.entries) {
      if (isRelocationTable) {
        // `Ref('other')` — a pointer-sized word holding another global's
        // address. The name is carried as a const String precisely because a
        // const initializer cannot reference a `final` field directly.
        if (entry is! InstanceConstant ||
            entry.classReference.canonicalName?.name != 'Ref') {
          throw DccLowerError(
            '"$name" is a `List<Ref>` but contains a ${entry.runtimeType}. '
            'Every element must be `Ref(\'someTableName\')`.',
          );
        }
        final values = entry.fieldValues.values.toList();
        final symbol = values.length == 1 ? values.single : null;
        if (symbol is! StringConstant) {
          throw DccLowerError(
            '"$name": Ref must hold a single constant string naming another '
            '`@rodata` table',
          );
        }
        elements.add(DCConstAddrOf(symbol.value));
        continue;
      }
      if (entry is! IntConstant) {
        throw DccLowerError(
          '"$name" contains a ${entry.runtimeType} element, but its declared '
          'type says the elements are integers. Use `List<Ref>` for a table '
          'of addresses.',
        );
      }
      elements.add(DCConstInt(elementType, entry.value));
    }

    globals.add(
      DCGlobal(
        linkName: name,
        // A relocation table's elements are pointer-sized. `usize` rather
        // than `u64` so the width follows the target if a 32-bit one is ever
        // added, instead of being wrong silently.
        initializer: DCConstArray(elementType ?? DCInt.usize, elements),
        alignBytes: elementType == null ? 8 : _byteWidthOfInt(elementType),
      ),
    );
  }
  return globals;
}

/// The element type of a `@rodata` table, from its DECLARED type.
///
/// The declared type is the ONLY place the width survives: the constant
/// erases every sized-int extension type back to a bare `IntConstant`, so
/// `List<int>` and `List<u64>` produce byte-identical constants. A bare
/// `List<int>` is therefore rejected — not for strictness, but because it
/// does not carry the information codegen needs, and guessing 64-bit would
/// silently read at the wrong stride if it were meant to be narrower.
DCInt? _rodataElementType(DartType declared, String name) {
  // `classReference.canonicalName`, NOT `classNode`. `List` is a dart:core
  // class and dcc-lower compiles with --no-link-platform, so `classNode`
  // throws "Reference to dart:core::List is not bound to an AST node" —
  // the same unbound-platform-node trap ADR-0014 hit with `bool`. The
  // canonical name is readable without binding anything.
  if (declared is InterfaceType &&
      declared.classReference.canonicalName?.name == 'List' &&
      declared.typeArguments.length == 1) {
    final arg = declared.typeArguments.single;
    // `List<Ref>` — a table of relocations, one pointer-sized word each.
    if (arg is InterfaceType &&
        arg.classReference.canonicalName?.name == 'Ref') {
      return null; // signals "relocation table"; caller uses pointer width
    }
    if (arg is ExtensionType) {
      switch (arg.extensionTypeDeclaration.name) {
        case 'u8':
          return DCInt.u8;
        case 'u16':
          return DCInt.u16;
        case 'u32':
          return DCInt.u32;
        case 'u64':
          return DCInt.u64;
      }
    }
  }
  throw DccLowerError(
    '"$name" must be declared `List<u8>`, `List<u16>`, `List<u32>`, '
    '`List<u64>` or `List<Ref>` (got $declared). A bare `List<int>` is '
    'rejected because the element width survives ONLY in the declared type — '
    'the constant erases it — so `List<int>` would leave the emitted stride '
    'ambiguous.',
  );
}

int _byteWidthOfInt(DCInt type) => switch (type.width) {
      IntWidth.w8 => 1,
      IntWidth.w16 => 2,
      IntWidth.w32 => 4,
      IntWidth.w64 => 8,
      IntWidth.wSize => 8,
    };

class DccLowerError extends Error {
  final String message;
  DccLowerError(this.message);

  @override
  String toString() => 'DccLowerError: $message';
}
