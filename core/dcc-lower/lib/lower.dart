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
import 'dart:convert';

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

/// The DC-IR type for `Str` (ADR-0055): a by-value `{bytes, length}` slice,
/// UTF-8 and non-owning. Same by-value struct treatment as `resultStructType`
/// — one concrete shape, so a fixed constant rather than a per-site layout.
const DCStruct strStructType = DCStruct('Str', [
  DCStructField('bytes', DCPointer(DCInt.u8)),
  DCStructField('length', DCInt.u64),
]);

/// Lowers the DCDart source at [dartSourcePath] to a [DCModule].
///
/// [preludeUri] identifies core/runtime/dc-core-bare/prelude.dart — see this
/// file's header for why matching happens by URI, not name alone.
Future<DCModule> lowerToDCModule(
  String dartSourcePath, {
  required Uri preludeUri,
  /// Run ADR-0025's redundant-pair elision. Always true for a real build.
  ///
  /// Exists so elision EFFECTIVENESS can be measured: nothing in this tree
  /// could previously answer "how many pairs does the pass actually remove on
  /// this program", because the pass ran unconditionally inside lowering and
  /// `dc-objdump --arc` therefore only ever saw the post-elision counts.
  /// Comparing the two is what turns "elision fires" -- which its unit tests
  /// prove -- into "elision removes N of M pairs HERE", which is the number
  /// that decides whether an ARC benchmark is measuring ARC or measuring a
  /// missing optimisation.
  bool elide = true,
  /// Filled with per-function elision statistics when supplied. Diagnostic
  /// only; nothing in a build reads it.
  Map<String, ElisionStats>? elisionStats,
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

    // (ADR-0052) Monomorphization queue: mangled name -> what to specialize.
    final pendingSpecializations = <String, _Specialization>{};
    final emittedSpecializations = <String>{};

    // (ADR-0055) String literals discovered while lowering. Interned by
    // CONTENT, so two identical literals share one .rodata global -- they are
    // immutable and non-owning, so nothing can tell them apart, and this is
    // the one place merging identical constants is unambiguously right
    // (contrast ADR-0040's descriptors, where identity matters).
    final stringLiterals = <String, String>{};

    // (ADR-0057) Non-capturing local functions discovered while lowering,
    // hoisted to top-level symbols. Seeded with every top-level procedure
    // name first, so a hoisted symbol can never silently shadow one.
    final hoister = _ClosureHoister();
    hoister.claimed.addAll(targetLibrary.procedures.map((p) => p.name.text));

    final functions = <DCFunction>[];
    for (final proc in targetLibrary.procedures) {
      if (!_hasMarkerAnnotation(proc.annotations, '_Bare', preludeUri)) continue;
      // (ADR-0052) A generic function is a TEMPLATE, not a function. It has
      // no single machine representation -- `T` has no size -- so nothing is
      // emitted for it here. One specialization per distinct type argument is
      // emitted instead, discovered from call sites below.
      if (proc.function.typeParameters.isNotEmpty) continue;
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
        _BareFunctionLowerer(proc, preludeUri, structLayouts, heapLayouts, externNames,
                globalNames, hoister, null, pendingSpecializations, const {}, stringLiterals)
            .lower(),
      );
    }

    // (ADR-0043 + ADR-0054) Every NON-generic HeapObject subclass in this
    // library is its own single instantiation, registered here so that the
    // drain below emits its methods and destructor whether or not anything
    // constructs it -- which is exactly what the pre-ADR-0054 code did by
    // walking `targetLibrary.classes` directly. A GENERIC class is
    // deliberately NOT registered here: it is a template with no layout, and
    // its instantiations arrive from use sites during lowering, the same way
    // ADR-0052's function specializations do.
    for (final cls in targetLibrary.classes) {
      if (!heapLayouts.extendsHeapObject(cls)) continue;
      if (cls.typeParameters.isNotEmpty) continue;
      heapLayouts.register(_ClassInstance(cls, const []));
    }

    // (ADR-0052, extended by ADR-0054, extended again by ADR-0057) Drain the
    // monomorphization queues.
    //
    // There are THREE of them and they feed each other, which is why this is
    // one fixpoint loop rather than three sequential drains:
    //
    //   * lowering a function specialization can construct `Box<u64>`,
    //     adding a CLASS instantiation;
    //   * lowering `Box<u64>`'s methods can call `pick<u64>`, adding a
    //     FUNCTION specialization;
    //   * either of those bodies can declare a local function, adding a
    //     HOISTED body -- whose own body can in turn call a generic or
    //     construct a generic class, feeding both queues above.
    //
    // Sequential drains would emit whichever kind the later drain handled and
    // silently drop anything an earlier kind discovered after its own drain
    // had finished. All three queues are keyed by mangled/link name, so each
    // distinct (function or class, type arguments) pair is emitted exactly
    // once no matter how many sites request it. That keying IS the
    // deduplication -- there is no separate identical-body merge step, and
    // none is needed.
    final emittedInstantiations = <String>{};
    var progressed = true;
    while (progressed) {
      progressed = false;

      while (pendingSpecializations.isNotEmpty) {
        final entry = pendingSpecializations.entries.first;
        pendingSpecializations.remove(entry.key);
        if (emittedSpecializations.contains(entry.key)) continue;
        emittedSpecializations.add(entry.key);
        progressed = true;
        functions.add(
          _BareFunctionLowerer(
            entry.value.proc,
            preludeUri,
            structLayouts,
            heapLayouts,
            externNames,
            globalNames,
            hoister,
            null,
            pendingSpecializations,
            entry.value.substitution,
            stringLiterals,
          ).lower(linkNameOverride: entry.key),
        );
      }

      // (ADR-0057) Hoisted non-capturing local functions.
      while (hoister.pending.isNotEmpty) {
        final entry = hoister.pending.entries.first;
        hoister.pending.remove(entry.key);
        if (hoister.emitted.contains(entry.key)) continue;
        hoister.emitted.add(entry.key);
        progressed = true;
        functions.add(
          _BareFunctionLowerer(
            entry.value.enclosingProc,
            preludeUri,
            structLayouts,
            heapLayouts,
            externNames,
            globalNames,
            hoister,
            // Deliberately NO receiver instance, even when the local function
            // was written inside an instance method: a body that mentioned
            // `this` would be capturing, and is rejected at the hoist site.
            null,
            pendingSpecializations,
            entry.value.typeSubstitution,
            stringLiterals,
            entry.value,
          ).lower(),
        );
      }

      // (ADR-0054) One set of method bodies and (if the layout has a
      // heap-typed field) one destructor per class INSTANTIATION.
      // `.toList()` because emitting a member can register further
      // instantiations into the very map being iterated.
      for (final key in heapLayouts.instantiations.keys.toList(growable: false)) {
        if (emittedInstantiations.contains(key)) continue;
        final inst = heapLayouts.instantiations[key];
        if (inst == null) continue;
        emittedInstantiations.add(key);
        progressed = true;

        for (final proc in inst.cls.procedures) {
          if (proc.isStatic || proc.isAbstract || proc.isExternal) continue;
          if (proc.kind != ProcedureKind.Method) {
            // Getters/setters/operators on a HeapObject are not lowered yet;
            // saying so beats emitting nothing and letting the call site fail
            // with a confusing "has no field" error later.
            throw DccLowerError(
              '"${inst.cls.name}.${proc.name.text}" is a ${proc.kind.name}; '
              'only plain instance methods are lowered on a HeapObject '
              'subclass (docs/decisions/0043-instance-methods.md)',
            );
          }
          // (ADR-0054, GAP-0055) A method carrying its OWN type parameters is
          // a template even after the CLASS is instantiated -- it would need
          // one body per (class instantiation x method type arguments) pair,
          // which this drain does not produce. Skipped here rather than
          // lowered into a body with `R` unbound; the call site refuses it by
          // name.
          if (proc.function.typeParameters.isNotEmpty) continue;
          functions.add(
            _BareFunctionLowerer(
              proc,
              preludeUri,
              structLayouts,
              heapLayouts,
              externNames,
              globalNames,
              hoister,
              inst,
              pendingSpecializations,
              inst.substitution,
              stringLiterals,
            ).lower(linkNameOverride: methodLinkName(key, proc.name.text)),
          );
        }

        // (ADR-0022, per-instantiation since ADR-0054) These are never
        // written by the user, only referenced by name (from Alloc's cls
        // header write) and called indirectly (from Release's codegen).
        final destructorName = heapLayouts.destructorNameFor(inst);
        if (destructorName != null) {
          functions.add(_buildDestructor(destructorName, heapLayouts.layoutFor(inst)));
        }
      }
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

    // (ADR-0022's destructor synthesis used to live here, walking
    // `targetLibrary.classes`. Since ADR-0054 it is part of the
    // instantiation drain above, because "does this class need a
    // destructor" is only answerable once `T` is known.)

    // (ADR-0025) Redundant-pair removal, applied to every function --
    // user-lowered and synthesized destructors alike. Real M2 exit-
    // criterion scope (ROADMAP.md), not M3-only, per docs/known-gaps.md
    // GAP-0017 item 2's correction.
    final List<DCFunction> elidedFunctions;
    if (!elide) {
      elidedFunctions = functions;
    } else {
      // (ADR-0066 rule T) The refcount-transparency summary is computed ONCE,
      // over the PRE-elision module -- every function including synthesized
      // destructors -- and handed to every per-function elision run. The
      // summary's validity for the POST-elision code the backend actually
      // emits is argued in the ADR (elision only deletes provably-paired
      // intervals and null no-ops, neither of which can create a decrement).
      final transparentCallees = computeRefcountTransparentCallees(functions);
      // The stats map is bound to a non-nullable local before the closure so
      // the closure never has to re-prove it is non-null -- no `!`, per
      // CLAUDE.md rule 3.
      final statsSink = elisionStats;
      if (statsSink == null) {
        elidedFunctions = functions
            .map((f) =>
                elideRedundantRetainReleasePairs(f, null, transparentCallees))
            .toList();
      } else {
        elidedFunctions = functions.map((f) {
          final stats = ElisionStats();
          final out =
              elideRedundantRetainReleasePairs(f, stats, transparentCallees);
          statsSink[f.linkName] = stats;
          return out;
        }).toList();
      }
    }

    // (ADR-0055) Emit one .rodata global per distinct string literal. Done
    // after ALL lowering so every literal -- including those inside
    // monomorphized specializations -- is present.
    for (final entry in stringLiterals.entries) {
      globals.add(
        DCGlobal(
          linkName: entry.value,
          initializer: DCConstArray(DCInt.u8, [
            for (final byte in utf8.encode(entry.key)) DCConstInt(DCInt.u8, byte),
          ]),
          alignBytes: 1,
        ),
      );
    }

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
    if (field.heapFieldInstance == null) continue; // scalar field -- nothing to release
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
/// `heapFieldInstance` (ADR-0020, extended by ADR-0022, and widened from a
/// bare `Class` to a `_ClassInstance` by ADR-0054): non-null iff `type` is
/// `DCHeapPointer` -- the CONCRETE class INSTANTIATION this field points
/// to, which `type` alone can't say (it's always the same
/// `DCHeapPointer(DCVoid())` placeholder, GAP-0003). Needed for
/// destructor-cascade resolution (`_HeapLayouts.destructorNameFor`) --
/// always `null` for `_StructField`s built by `_StructLayouts` (`@packed`
/// fields are never heap-typed).
///
/// It has to be an INSTANTIATION rather than a class because `Box<u64>` and
/// `Box<Node>` are the same `Class` and carry different destructor
/// obligations: one has none at all, the other must release its field.
class _StructField {
  final String name;
  final DCType type;
  final int offset;
  final _ClassInstance? heapFieldInstance;
  const _StructField(this.name, this.type, this.offset, {this.heapFieldInstance});
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
///
/// (ADR-0054) Everything here is keyed by a [_ClassInstance] -- a class PLUS
/// its type arguments -- rather than by a bare `Class`, because `Box<u64>`
/// and `Box<u32>` are one `Class` with two different field layouts, two
/// different payload sizes and two different ARC shapes. A non-generic class
/// is simply the instantiation with an empty type-argument list, whose
/// mangled name is its own name, so nothing that predates generic classes
/// changes name, layout or symbol.
class _HeapLayouts {
  final Uri preludeUri;
  final Map<String, List<_StructField>> _cache = {};
  final Map<String, String?> _destructorCache = {};

  /// (ADR-0054) Every class instantiation discovered so far, keyed by
  /// mangled name. **This map is what bounds code size**: two call sites
  /// asking for `Box<u64>` produce one key and therefore one layout, one
  /// destructor and one copy of each method. It is also the drain queue --
  /// `lowerToDCModule` emits the members of everything in here, and
  /// lowering those members can add more.
  final Map<String, _ClassInstance> instantiations = {};

  _HeapLayouts(this.preludeUri);

  bool extendsHeapObject(Class cls) => _extendsPreludeMarker(cls, 'HeapObject', preludeUri);

  /// The single instantiation of a NON-generic class. Refuses a generic one
  /// by name rather than silently treating `Box` as `Box<dynamic>`: a class
  /// whose type arguments are not known has no layout, and pretending it
  /// does is exactly the bug this ADR exists to prevent.
  _ClassInstance instanceOfNonGeneric(Class cls, {required String context}) {
    if (cls.typeParameters.isNotEmpty) {
      throw DccLowerError(
        '"$context": "${cls.name}" is generic and was reached without type '
        'arguments. A generic class is a TEMPLATE -- it has no layout, no '
        'payload size and no destructor until `T` is known '
        '(docs/decisions/0054-generic-classes.md).',
      );
    }
    return register(_ClassInstance(cls, const []));
  }

  /// Records [inst] and returns the canonical instance for its mangled name,
  /// so identical instantiations reached from different call sites are one
  /// object and one emitted body.
  _ClassInstance register(_ClassInstance inst) {
    final existing = instantiations[inst.mangledName];
    if (existing != null) return existing;
    _checkInstantiationBudget(inst.cls.name, inst.typeArgs, instantiations.length);
    instantiations[inst.mangledName] = inst;
    return inst;
  }

  List<_StructField> layoutFor(_ClassInstance inst) {
    final cached = _cache[inst.mangledName];
    if (cached != null) return cached;
    register(inst);

    final substitution = inst.substitution;
    final fields = <_StructField>[];
    var offset = 0;
    for (final field in inst.cls.fields) {
      // (ADR-0054) Substitute FIRST. `final T value` is a
      // `TypeParameterType` in the Kernel IR and has no width; once `T` is
      // resolved this is an ordinary field type and `_lowerFieldType`
      // needs no knowledge of generics at all -- the same property
      // ADR-0052 relied on for signatures.
      final fieldType = _substituteType(field.type, substitution);
      // heapLayouts: this -- ADR-0020. A HeapObject subclass's OWN field
      // can itself be HeapObject-typed (`class BoxHolder extends HeapObject
      // { final Box inner; ... }`); `@packed` struct fields (below,
      // `_StructLayouts.layoutFor` calls `_lowerFieldType` WITHOUT this
      // argument) never get this recognition -- a raw-memory `@packed`
      // struct has no ARC involvement at all, so a heap reference inside
      // one would be meaningless (nothing would ever retain/release it).
      final type = _lowerFieldType(
          fieldType, preludeUri, inst.mangledName, field.name.text, heapLayouts: this);
      _ClassInstance? heapFieldInstance;
      if (type is DCHeapPointer && fieldType is InterfaceType) {
        // Registered, not merely recorded: a field of type `Box<Node>`
        // makes `Box<Node>` reachable even if no constructor for it is
        // written anywhere in this unit, and its destructor and methods
        // still have to exist.
        heapFieldInstance =
            register(_ClassInstance(fieldType.classNode, fieldType.typeArguments));
      }
      fields.add(_StructField(field.name.text, type, offset,
          heapFieldInstance: heapFieldInstance));
      offset += _byteWidth(type, inst.mangledName, field.name.text);
    }
    _cache[inst.mangledName] = fields;
    return fields;
  }

  /// The link name of [inst]'s destructor (ADR-0022), or `null` if it has
  /// no heap-typed fields -- the overwhelmingly common case, and the only
  /// one that existed before that ADR (e.g. `Box`, whose only field is a
  /// `u64`). A destructor's own body releases each heap-typed field in
  /// turn (`_buildDestructor`); if one of THOSE fields' classes also has a
  /// destructor, that cascades automatically at runtime through `cls`
  /// (docs/decisions/0022) with no recursion needed here -- this method
  /// only decides whether THIS instantiation needs a destructor at all, not
  /// what its transitive closure looks like.
  ///
  /// (ADR-0054) Note that this is answered PER INSTANTIATION. `Box<u64>`
  /// returns null and `Box<Node>` returns `Box$Node_dtor` -- from the same
  /// class. Answering it per CLASS would either release an integer as if it
  /// were a pointer, or leak the reference, depending on which way it
  /// guessed.
  String? destructorNameFor(_ClassInstance inst) {
    final key = inst.mangledName;
    if (_destructorCache.containsKey(key)) return _destructorCache[key];
    final fields = layoutFor(inst);
    final hasHeapField = fields.any((f) => f.heapFieldInstance != null);
    final name = hasHeapField ? '${key}_dtor' : null;
    _destructorCache[key] = name;
    return name;
  }

  int payloadSizeBytes(_ClassInstance inst) {
    final fields = layoutFor(inst);
    if (fields.isEmpty) return 0;
    final last = fields.last;
    return last.offset + _byteWidth(last.type, inst.mangledName, last.name);
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
  late final String context = hoistedBody?.linkName ?? proc.name.text;
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
  ///
  /// `heapDepth`/`weakDepth` are the per-iteration release policy's half of
  /// this map: the `_heapLocals`/`_weakLocals` lengths recorded at the
  /// moment that loop's BODY began lowering. Both `break` and `continue`
  /// LEAVE the current iteration, so every heap/weak local declared inside
  /// the body being left — i.e. everything pushed at or beyond those
  /// depths — has to be released on that edge, exactly as it is on the
  /// body's normal fall-through. Recording the depth per LABEL rather than
  /// using "everything above the innermost loop" is what makes a labelled
  /// `break outer;` out of a nested loop release the INNER body's objects
  /// AND the outer body's, in one unwind, with no extra bookkeeping.
  final Map<
      LabeledStatement,
      ({
        BlockId target,
        List<VariableDeclaration> vars,
        int heapDepth,
        int weakDepth,
      })> _labelTargets = {};
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

  /// The enclosing class INSTANTIATION when lowering an INSTANCE METHOD
  /// (ADR-0043; widened from `Class?` to `_ClassInstance?` by ADR-0054),
  /// null for a top-level `@bare` function.
  ///
  /// A method is lowered as an ordinary function whose FIRST parameter is
  /// the receiver — the same shape `_buildDestructor` already synthesizes
  /// for the destructor cascade (ADR-0022), and the same shape C uses. No
  /// dynamic dispatch is involved: every call site knows the concrete class
  /// statically, exactly as ADR-0022 observed for destructors.
  ///
  /// It is the instantiation rather than the class because `this.value`
  /// inside `Box<T>.unwrap` needs `Box<u64>`'s layout, not `Box`'s — which
  /// does not exist.
  final _ClassInstance? receiverInstance;

  /// (ADR-0052) Where newly-discovered specializations are queued, keyed by
  /// mangled name so each distinct (function, type arguments) pair is emitted
  /// exactly once however many call sites ask for it.
  final Map<String, _Specialization> pendingSpecializations;

  /// (ADR-0052) `T` -> the concrete type, when lowering a specialization.
  /// Empty for an ordinary function.
  final Map<String, DartType> typeSubstitution;

  /// (ADR-0055) String literal content -> its `.rodata` symbol name.
  /// Interned by content across the whole module.
  final Map<String, String> stringLiterals;

  /// (ADR-0057) Where non-capturing local functions found in this body are
  /// queued for emission as top-level symbols, and where their names are kept
  /// unique across the whole module.
  final _ClosureHoister hoister;

  /// (ADR-0057) Set when this lowerer is emitting a HOISTED local function
  /// rather than a `Procedure`: [proc] is then only the enclosing procedure,
  /// present for nothing but its identity, and the body and link name come
  /// from here instead.
  final _HoistedClosure? hoistedBody;

  /// (ADR-0057) Local functions in scope, by the `VariableDeclaration` that
  /// names them. Seeded from [hoistedBody] so a hoisted body can call its
  /// siblings and recurse into itself.
  final Map<VariableDeclaration, _LocalFunction> _localFunctions = {};

  /// (ADR-0057) The symbol this body is actually EMITTED under, set at the top
  /// of [lower]. Differs from [context] for an instance method (`Box_doubled`
  /// vs `doubled`, ADR-0043) and for a specialization (`pick$u64` vs `pick`,
  /// ADR-0052). Hoisted names must qualify by this, not by [context]: a local
  /// `g` inside `Box.doubled` and a local `g` inside a top-level `doubled`
  /// would otherwise both want `doubled$g`.
  String _emittedLinkName = '';

  _BareFunctionLowerer(
    this.proc,
    this.preludeUri,
    this.structLayouts,
    this.heapLayouts,
    this.externNames,
    this.globalNames,
    this.hoister, [
    this.receiverInstance,
    this.pendingSpecializations = const {},
    this.typeSubstitution = const {},
    this.stringLiterals = const {},
    this.hoistedBody,
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
    // (ADR-0057) Set FIRST: a local function discovered anywhere in this body
    // qualifies its hoisted symbol by the name this body is emitted under.
    _emittedLinkName = linkNameOverride ?? context;

    // (ADR-0057) A hoisted local function's body, not the procedure's.
    final hoisted = hoistedBody;
    final fn = hoisted == null ? proc.function : hoisted.node;
    if (hoisted != null) _localFunctions.addAll(hoisted.visibleLocalFunctions);

    final paramTypes = <DCType>[];
    final paramValues = <DCValue>[];

    // (ADR-0043) An instance method's receiver is param 0. Kernel does NOT
    // put `this` in `positionalParameters` -- it is implicit, reached via
    // `ThisExpression` -- so it is prepended here and bound to `_thisValue`
    // rather than to a VariableDeclaration.
    final self = receiverInstance;
    if (self != null) {
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
        // This implicit return is a scope exit exactly like an explicit
        // `return;` and must release everything `_lowerReturn` would:
        // tracked heap/weak locals AND `@owned` parameters. Skipping this
        // leaked 3 objects per call in tests/conformance/void-release/'s
        // churn (found by NEON N1's `tensorRelease(@owned Tensor t) {}`,
        // 2026-08-27 — a consuming release whose empty body IS the
        // operation, so the entire function was the missing release).
        _releaseHeapLocals(exceptDecl: null);
        _releaseWeakLocals(exceptDecl: null);
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
    // (ADR-0057) A named local function: `u64 dbl(u64 v) => v + v;` inside a
    // body. Emits NO instructions here -- the declaration itself is not code.
    // The body is hoisted to its own top-level symbol and every call site
    // resolves to it directly.
    if (stmt is FunctionDeclaration) {
      _hoistLocalFunction(stmt.variable, stmt.function, stmt.variable.name);
      return;
    }

    if (stmt is VariableDeclaration) {
      final init = stmt.initializer;
      // (ADR-0057) `final f = (u64 v) => ...;` -- the other spelling of the
      // same thing. Checked BEFORE `_lowerExpression`, because a function
      // expression is not a value this compiler can produce (that would need
      // a function-pointer type and an indirect call, GAP-0052); it is only
      // ever a definition bound to a name.
      if (init is FunctionExpression) {
        _hoistLocalFunction(stmt, init.function, stmt.name);
        return;
      }
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
          _lowerHeapFieldStore(
              expr,
              _instanceOfReceiver(expr.receiver, enclosingClass,
                  'the field store "${expr.interfaceTarget.name.text}"'));
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
        // (ADR-0065) DCFloat joins DCInt here: a float is a plain scalar
        // with no ownership questions, so reassignment is the same
        // rebinding it has always been for ints — `acc = acc + x` in an ML
        // kernel's accumulation loop is this exact shape.
        if (oldValue.type is! DCInt && oldValue.type is! DCFloat) {
          throw DccLowerError(
            '"$context": reassigning "${variable.name}" (type ${oldValue.type}) '
            'is not supported -- only scalar (u8/u32/u64/f32/f64) locals can '
            'be reassigned; heap- and weak-typed reassignment needs a real '
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

        // (ADR-0058) `Heap.free(p);` — void-returning, so it lands here
        // rather than in the expression path, the same split as
        // `Port.outb`/`Port.inb` and `Atomic.store`/`Atomic.load`.
        if (target.isStatic &&
            target.name.text == 'free' &&
            target.enclosingClass?.name == 'Heap' &&
            target.enclosingLibrary.importUri == preludeUri) {
          final args = expr.arguments.positional;
          if (args.length != 1) {
            throw DccLowerError(
              '"$context": Heap.free takes exactly one argument (the pointer '
              'Heap.allocate returned)',
            );
          }
          final block = _lowerExpression(args.single);
          if (block.type is! DCPointer) {
            throw DccLowerError(
              '"$context": Heap.free takes a pointer, got ${block.type}',
            );
          }
          _addInstr(FreeRaw(pointer: block));
          return;
        }

        // (ADR-0055) `Atomic.store(p, v);` — the one void-returning member of
        // `Atomic`, so it lands here for the same reason `Port.outb` does.
        if (target.isStatic &&
            target.enclosingClass?.name == 'Atomic' &&
            target.name.text == 'store' &&
            target.enclosingLibrary.importUri == preludeUri) {
          final (pointer, elementType) = _lowerAtomicPointerArg(expr, 'store');
          final args = expr.arguments.positional;
          if (args.length != 2) {
            throw DccLowerError(
              '"$context": Atomic.store takes a pointer and a value',
            );
          }
          final value = _lowerExpression(args[1]);
          if (value.type != elementType) {
            throw DccLowerError(
              '"$context": Atomic.store writes a ${value.type} through a '
              'Pointer<$elementType>. The widths must match exactly — there is '
              'no implicit widening (spec §4.1), and a narrowing atomic store '
              'would silently change which bytes are updated indivisibly.',
            );
          }
          _addInstr(AtomicStore(pointer: pointer, value: value));
          return;
        }

        // (ADR-0056) `fence(Ordering.release);` — a top-level function, which
        // is spec §6's own spelling. Void by nature: a barrier computes
        // nothing, it constrains the movement of everything around it.
        if (target.isStatic &&
            target.enclosingClass == null &&
            target.name.text == 'fence' &&
            target.enclosingLibrary.importUri == preludeUri) {
          final args = expr.arguments.positional;
          if (args.length != 1) {
            throw DccLowerError(
              '"$context": fence takes exactly one Ordering argument',
            );
          }
          _addInstr(Fence(ordering: _lowerOrdering(args.single)));
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
      // (ADR-0057) A local function called for effect rather than for a value.
      // Not lowered: nothing in examples/m2-closure needs it, and this file's
      // scope rule is to extend on a real target rather than speculatively.
      // Named explicitly so the diagnostic points at the actual restriction
      // instead of the generic list below.
      if (expr is LocalFunctionInvocation || expr is FunctionInvocation) {
        // (ADR-0060) A call THROUGH A POINTER is lowered in statement
        // position, because a void callback invoked for effect
        // (`onEach(item);`) is the ordinary shape of the thing this unit
        // exists for -- unlike a void LOCAL function called as a statement,
        // which ADR-0057 left unimplemented for want of a real case and
        // which still is.
        if (expr is FunctionInvocation && _calleeOf(expr) == null) {
          _lowerIndirectCall(
            _lowerCalleeValue(expr),
            expr.arguments,
            allowVoid: true,
            what: 'the called function pointer',
          );
          return;
        }
        throw DccLowerError(
          '"$context": a call to a local function is only lowered in '
          'EXPRESSION position — bind the result to a local '
          '(`final _unused = f(...);`). A void local function called as a '
          'statement is not implemented (ADR-0057)',
        );
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
      // PER-ITERATION RELEASE, on the `break`/`continue` edge.
      //
      // Both spellings leave the current iteration, so every heap/weak local
      // declared inside the loop body being left dies here, on THIS path,
      // and must be released BEFORE the edge is taken -- not after, because
      // the target block is reachable from other paths that already released
      // their own copies, and a release placed there would run once per
      // predecessor for objects that no longer exist.
      //
      // The stacks are deliberately NOT truncated: lowering continues into
      // sibling paths (this `break` is typically inside one arm of an `if`,
      // whose other arm still has the same locals live), and the enclosing
      // scope -- `_lowerIf`'s own truncation, or `_lowerWhile`'s below --
      // owns removing them. This block is terminated on the next line, so no
      // further instruction can be appended to the path just released.
      _releaseScopeFrom(heapDepth: entry.heapDepth, weakDepth: entry.weakDepth);
      // Carry the CURRENT values of the loop variables across the edge --
      // the whole reason the exit block needs parameters at all.
      _addInstr(Branch(
        target: entry.target,
        args: [for (final v in entry.vars) _trackedValue(v)],
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
      final mergeType = valuesBeforeIf[v]!.type;
      // DCFloat allowed alongside DCInt (ADR-0065): same scalar-merge
      // mechanics, the block param just carries a float type.
      if (mergeType is! DCInt && mergeType is! DCFloat) {
        throw DccLowerError(
          '"$context": "${v.name}" (type $mergeType) is reassigned in a '
          'branch of this if/else that falls through -- only scalar '
          '(u8/u16/u32/u64/f32/f64) locals can be reassigned this way, same '
          'rule as ADR-0027\'s straight-line reassignment',
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
  ///   - Heap- and weak-typed locals declared in the loop BODY are now
  ///     supported, by a PER-ITERATION release policy. This used to be a
  ///     hard refusal, and the refusal was correct for the policy that
  ///     existed: ADR-0016/0017's naive scheme releases tracked locals only
  ///     before a `return`, and a loop's back edge is not a `return`, so a
  ///     heap local declared in the body was allocated afresh every
  ///     iteration and released at most once — one leaked object per
  ///     iteration, and with a 64-slot arena (ADR-0015) that is a trap at
  ///     iteration 65, not a slow leak. Refusing was the right call over
  ///     shipping that.
  ///
  ///     What the refusal was protecting is now provided rather than
  ///     removed: a body-scoped heap/weak local is released on EVERY path
  ///     that leaves the body — the normal fall-through into the back edge,
  ///     every `continue`, every `break` (including a labelled one out of a
  ///     nested loop, which unwinds both bodies), and every `return`
  ///     (already covered, since `_lowerReturn` releases the whole tracking
  ///     stack). The scope mark is `_heapLocals`/`_weakLocals`'s length at
  ///     body entry; `_releaseScopeFrom` emits the releases on a path and
  ///     `_forgetLocalsFrom` drops the tracking once every path is lowered.
  ///
  ///     The invariant this has to hold, and the one the old refusal
  ///     doubted: releases equal allocations per iteration. A loop of N
  ///     iterations allocating one object must show N releases at runtime
  ///     and equal `alloc`/`release` counts under `dc-objdump --arc`, which
  ///     `tests/conformance/loopheap` asserts both of.
  ///
  ///     Still refused, and this is the remaining hole: a heap/weak local
  ///     declared inside an `if`-branch that FALLS THROUGH to code after
  ///     the `if` (`_lowerIf`'s own `branchToMerge` check). That is an
  ///     if/else-merge ownership question, not a loop one, and it is
  ///     unchanged by this policy — a body-scoped local declared in a
  ///     branch that `break`s, `continue`s or `return`s instead is fine.
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
      // DCFloat allowed alongside DCInt (ADR-0065): a float accumulator
      // (`sum = sum + a[i] * b[i]`) is the defining loop-carried value of
      // every ML kernel this feature exists for.
      if (current.type is! DCInt &&
          current.type is! DCFloat &&
          current.type is! DCHeapPointer) {
        throw DccLowerError(
          '"$context": loop-carried variable "${v.name}" has type '
          '${current.type} — only scalar (u8/u32/u64/f32/f64) and heap-typed '
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

    // THE BODY SCOPE MARK, and the whole per-iteration release policy hangs
    // off it. Everything pushed onto `_heapLocals`/`_weakLocals` from here
    // until the body finishes lowering was declared INSIDE the body, which
    // means it is a brand-new object on every iteration — the variable is
    // overwritten by the next iteration's `Alloc`, so if nothing releases
    // the previous one it is unreachable and never freed. One leak per
    // iteration exhausts the arena, so this is a trap, not a slow leak.
    //
    // Recorded BEFORE the labels are registered because `break` and
    // `continue` both unwind to exactly this depth (see `_labelTargets`).
    final heapLocalsBeforeBody = _heapLocals.length;
    final weakLocalsBeforeBody = _weakLocals.length;

    // Register both label kinds before lowering the body, since a `break` or
    // `continue` inside it resolves through this map.
    if (breakLabel != null) {
      _labelTargets[breakLabel] = (
        target: exitBlockId,
        vars: loopVars,
        heapDepth: heapLocalsBeforeBody,
        weakDepth: weakLocalsBeforeBody,
      );
    }
    final body = stmt.body;
    if (body is LabeledStatement) {
      // A label wrapping the loop BODY is `continue`: branch to the header,
      // which is exactly what the back edge below does.
      _labelTargets[body] = (
        target: continueTarget,
        vars: loopVars,
        heapDepth: heapLocalsBeforeBody,
        weakDepth: weakLocalsBeforeBody,
      );
    }

    _startBlock(bodyBlockId, const []);
    // Unwrap the continue-label if present: it was registered above, and
    // what actually needs lowering is the statement inside it.
    _lowerBranchBody(body is LabeledStatement ? body.body : body);
    // Only wire the back edge if some path through the body still falls
    // through (_blockOpen) — a body where every path returns has no
    // reachable back edge at all, which is a legal (if degenerate) program:
    // the loop's condition is checked once, and if the body is entered it
    // always returns before completing a second iteration.
    if (_blockOpen) {
      // NORMAL FALL-THROUGH out of the body: this iteration's objects die
      // here. Released BEFORE the back-edge `Branch`, for two reasons that
      // both matter. Placing them after would be unreachable dead code; and
      // placing them at the TOP of the header (the "release last
      // iteration's objects on entry" alternative) is a use-after-free the
      // moment a loop-carried variable, or the returned value, still refers
      // to one of them — the header is also reached from the pre-loop entry
      // edge, where those values do not exist at all.
      //
      // For a `for` loop `continueTarget` is the update block, so the update
      // clause runs AFTER this release. That is fine and is the only correct
      // order available: the update clause is scalar (ADR-0050 desugars only
      // `init; cond; update` where the loop-carried set is what the header's
      // phis carry), so it cannot read a body-scoped heap local — such a
      // local is out of scope in the update clause by Dart's own rules.
      _releaseScopeFrom(
        heapDepth: heapLocalsBeforeBody,
        weakDepth: weakLocalsBeforeBody,
      );
      final backArgs = [for (final v in loopVars) _trackedValue(v)];
      _addInstr(Branch(target: continueTarget, args: backArgs));
      _finishBlock();
    }
    // Body-scoped locals are gone on EVERY path now — fall-through and every
    // `break`/`continue` released their own copy, and a `return` inside the
    // body released the lot through `_lowerReturn`. Drop them from the
    // tracking stacks so nothing downstream (the update block, the exit
    // block, the rest of the function, an enclosing `return`) releases them
    // a second time, and drop their `_values` entries so no later block can
    // name a DCValue defined in the body block that does not dominate it.
    _forgetLocalsFrom(
      heapDepth: heapLocalsBeforeBody,
      weakDepth: weakLocalsBeforeBody,
    );

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

  /// The current DCValue bound to a local this lowering is still tracking.
  ///
  /// A separate accessor rather than `_values[decl]!` because CLAUDE.md rule
  /// 3 forbids `!`, and because a miss here is a real dcc-lower bug worth
  /// naming: every declaration in `_heapLocals`/`_weakLocals` was put there
  /// by the same code path that wrote `_values[decl]`, so a null means the
  /// two went out of sync.
  DCValue _trackedValue(VariableDeclaration decl) {
    final value = _values[decl];
    if (value == null) {
      throw DccLowerError(
        '"$context": tracked local "${decl.name}" has no current DCValue — '
        'dcc-lower bug: _heapLocals/_weakLocals and _values disagree',
      );
    }
    return value;
  }

  /// PER-ITERATION (and per-scope) RELEASE: emit a `Release`/`DropWeak` for
  /// every heap/weak local declared at or beyond the given tracking depths,
  /// innermost first, WITHOUT truncating the stacks.
  ///
  /// Not truncating is the point. This runs on ONE path out of a scope
  /// (`break`, `continue`, the body's fall-through), while other paths out
  /// of the same scope are lowered afterwards and need the same locals still
  /// tracked so they can release their own copies. Whoever owns the scope
  /// removes them once, after every path has been lowered —
  /// `_forgetLocalsFrom` below.
  ///
  /// Innermost-first (reverse declaration order) mirrors normal scope exit.
  /// It is not required for correctness — these are independent refcount
  /// decrements — but a destructor cascade (ADR-0022) freeing an object that
  /// holds a reference to an earlier one is much easier to read in that
  /// order.
  void _releaseScopeFrom({required int heapDepth, required int weakDepth}) {
    for (var i = _heapLocals.length - 1; i >= heapDepth; i--) {
      _addInstr(Release(object: _trackedValue(_heapLocals[i])));
    }
    for (var i = _weakLocals.length - 1; i >= weakDepth; i--) {
      _addInstr(DropWeak(object: _trackedValue(_weakLocals[i])));
    }
  }

  /// Stop tracking every heap/weak local at or beyond the given depths, and
  /// forget their `_values` bindings too.
  ///
  /// Called once, after EVERY path out of a scope has been lowered and has
  /// released its own copies. Dropping the `_values` entries as well as the
  /// stack entries is what keeps a later block from naming a DCValue that
  /// was defined inside the scope and therefore does not dominate it.
  void _forgetLocalsFrom({required int heapDepth, required int weakDepth}) {
    for (var i = _heapLocals.length - 1; i >= heapDepth; i--) {
      _values.remove(_heapLocals[i]);
    }
    _heapLocals.removeRange(heapDepth, _heapLocals.length);
    for (var i = _weakLocals.length - 1; i >= weakDepth; i--) {
      _values.remove(_weakLocals[i]);
    }
    _weakLocals.removeRange(weakDepth, _weakLocals.length);
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
    // (ADR-0057) A call to a hoisted local function is a call to a `@bare`
    // function under a different spelling, so it transfers ownership out by
    // the same ADR-0019 convention. Leaving these two node types out would
    // make `final b = mk(v);` retain a reference nobody else holds and leak
    // it — the exact bug the StaticInvocation case above exists to prevent.
    if (expr is LocalFunctionInvocation || expr is FunctionInvocation) return true;
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
        // (ADR-0060, was ADR-0057's rejection) A local function's name in
        // VALUE position. It has a symbol, so a function pointer to it is
        // exactly what it means. The `DCFuncPtr` type is built from the
        // function's own declaration here, so its `@owned` convention is
        // derived rather than assumed — see `_funcPtrTypeOfNode`.
        final localFn = _localFunctions[expr.variable];
        if (localFn != null) {
          return _lowerFuncRef(
            localFn.linkName,
            localFn.node,
            what: 'local function "${expr.variable.name}"',
          );
        }
        throw DccLowerError(
          '"$context": reference to unrecognized variable "${expr.variable.name}"',
        );
      }
      return value;
    }

    // (ADR-0057) A call to a hoisted local function, in either of Kernel's two
    // spellings: `LocalFunctionInvocation` for a named local function, and
    // `FunctionInvocation` on a `VariableGet` for a function expression bound
    // to a local.
    if (expr is LocalFunctionInvocation || expr is FunctionInvocation) {
      final callee = _calleeOf(expr);
      if (callee == null) {
        // (ADR-0060) A call through a function-pointer VALUE — a parameter, a
        // local bound to a tear-off, or anything else of `DCFuncPtr` type.
        // This is what ADR-0057 could only reject.
        if (expr is FunctionInvocation) {
          final result = _lowerIndirectCall(
            _lowerCalleeValue(expr),
            expr.arguments,
            allowVoid: false,
            what: 'the called function pointer',
          );
          if (result == null) {
            throw DccLowerError(
              '"$context": internal error — _lowerIndirectCall returned no '
              'value with allowVoid: false (dcc-lower bug)',
            );
          }
          return result;
        }
        throw DccLowerError(
          '"$context": `LocalFunctionInvocation` naming a variable that is '
          'not a hoisted local function (dcc-lower bug, not a source error)',
        );
      }
      final arguments =
          expr is LocalFunctionInvocation ? expr.arguments : (expr as FunctionInvocation).arguments;
      final result = _lowerLocalCall(callee, arguments, allowVoid: false);
      if (result == null) {
        throw DccLowerError(
          '"$context": internal error — _lowerLocalCall returned no value '
          'with allowVoid: false (dcc-lower bug, not a source error)',
        );
      }
      return result;
    }

    // (ADR-0060) `final f = topLevelFn;` — a top-level function's name in
    // value position. TWO Kernel spellings, and which one arrives depends on
    // whether constant evaluation has run: the plain `StaticTearOff`
    // expression, or that same tear-off folded into a
    // `ConstantExpression(StaticTearOffConstant)`. The pipeline this compiler
    // uses (`dart compile kernel`) produces the folded form, so the second is
    // the one actually exercised — the first is kept because nothing
    // guarantees that stays true and the two mean exactly the same thing.
    if (expr is StaticTearOff) {
      return _lowerStaticTearOff(expr.target);
    }
    if (expr is ConstantExpression) {
      final constant = expr.constant;
      if (constant is StaticTearOffConstant) {
        return _lowerStaticTearOff(constant.target);
      }
    }

    // (ADR-0057) A function expression anywhere OTHER than a local variable's
    // initializer. There is no value to produce for it.
    if (expr is FunctionExpression) {
      throw DccLowerError(
        '"$context": a function expression is only lowered as the initializer '
        'of a local (`final f = (u64 v) => ...;`), where it names a function '
        'rather than producing a value. Here it would have to BE a value, '
        'which needs a function-pointer type DC-IR does not have '
        '(docs/known-gaps.md GAP-0052, ADR-0057)',
      );
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

          // Int -> float (ADR-0065): `u32.toF32()` / `u64.toF64()`. Unary
          // like the width conversions above, but lowers to `FConvert`
          // (`uitofp`, round to nearest even) rather than `IConvert` —
          // zext/trunc have no meaning against a float destination.
          final intToFloat = switch (op) {
            'toF32' => DCFloat.f32,
            'toF64' => DCFloat.f64,
            _ => null,
          };
          if (widthType != null && intToFloat != null) {
            final args = expr.arguments.positional;
            if (args.length != 1) {
              throw DccLowerError(
                '"$context": ${target.name.text} with ${args.length} '
                'arguments, expected 1 (the receiver)',
              );
            }
            final source = _lowerExpression(args.single);
            final dest = DCValue(_allocId(), intToFloat);
            _addInstr(FConvert(dest: dest, source: source));
            return dest;
          }

          // Float operators and conversions (ADR-0065) — the same
          // "<width>|<op>" member-name shape the sized ints use above,
          // dispatched on an 'f'-prefixed width. A separate block rather
          // than extra rows in the integer tables, because the instruction
          // family genuinely differs (no Overflow field, ordered FCmp
          // predicates, FConvert vs IConvert) — merging them would undo
          // the DCInt/DCFloat split (types.dart) at exactly the call site
          // it exists to protect.
          final floatType = switch (target.name.text.substring(0, sep)) {
            'f32' => DCFloat.f32,
            'f64' => DCFloat.f64,
            _ => null,
          };
          if (floatType != null) {
            // Same per-op dest-type rule as the integer table above: a
            // comparison consumes two floats and produces a DCBool.
            final floatDestType = switch (op) {
              '+' || '-' || '*' || '/' => floatType as DCType,
              '<' || '<=' || '>' || '>=' => const DCBool(),
              _ => null,
            };
            // ORDERED predicates (`o`-prefixed): any comparison against
            // NaN is false — IEEE-754's rule and upstream Dart's own
            // `double` semantics. `==`/`!=` are NOT here: extension types
            // cannot declare `operator ==` (same restriction the sized
            // ints hit, ADR-0035), so they arrive as `EqualsCall` and are
            // handled in `_lowerIntEquality`'s float branch.
            final emitFloat = switch (op) {
              '+' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(FAdd(dest: dest, lhs: lhs, rhs: rhs)),
              '-' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(FSub(dest: dest, lhs: lhs, rhs: rhs)),
              '*' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(FMul(dest: dest, lhs: lhs, rhs: rhs)),
              // `/` on floats only — never a zero-divisor trap (x/0.0 is a
              // defined IEEE result), and integers keep `~/` (ADR-0036,
              // superseded only in its float half by ADR-0065).
              '/' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(FDiv(dest: dest, lhs: lhs, rhs: rhs)),
              '<' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(FCmp(dest: dest, predicate: FCmpPredicate.olt, lhs: lhs, rhs: rhs)),
              '<=' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(FCmp(dest: dest, predicate: FCmpPredicate.ole, lhs: lhs, rhs: rhs)),
              '>' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(FCmp(dest: dest, predicate: FCmpPredicate.ogt, lhs: lhs, rhs: rhs)),
              '>=' => (DCValue dest, DCValue lhs, DCValue rhs) => _addInstr(FCmp(dest: dest, predicate: FCmpPredicate.oge, lhs: lhs, rhs: rhs)),
              _ => null,
            };
            if (emitFloat != null && floatDestType != null) {
              return _lowerU64Binary(expr, emitFloat, floatDestType);
            }

            // Unary members — `-x` and the explicit conversions. An
            // extension-type method/operator call passes only the receiver
            // positionally, same shape as `.toU8()` above.
            final unaryDest = switch (op) {
              'unary-' => floatType as DCType,
              'toF32' => DCFloat.f32, // f64 -> f32: fptrunc, round to nearest even
              'toF64' => DCFloat.f64, // f32 -> f64: fpext, exact
              // Truncate toward zero, saturating (llvm.fptoui.sat) — see
              // the prelude's toU64trunc doc for the exact contract.
              'toU32trunc' => DCInt.u32,
              'toU64trunc' => DCInt.u64,
              _ => null,
            };
            if (unaryDest != null) {
              final args = expr.arguments.positional;
              if (args.length != 1) {
                throw DccLowerError(
                  '"$context": ${target.name.text} with ${args.length} '
                  'arguments, expected 1 (the receiver)',
                );
              }
              final source = _lowerExpression(args.single);
              final dest = DCValue(_allocId(), unaryDest);
              if (op == 'unary-') {
                _addInstr(FNeg(dest: dest, operand: source));
              } else {
                _addInstr(FConvert(dest: dest, source: source));
              }
              return dest;
            }
          }
        }
      }

      // (ADR-0055) `Atomic.load(p)` / `Atomic.fetchAdd(p, v)` and friends --
      // every value-producing member of `Atomic`. `Atomic.store` is
      // void-returning and is recognized separately in `_lowerStatement`,
      // exactly as `Port.outb` is against `Port.inb`.
      //
      // Recognized HERE, ahead of the generic-call path below, so a call to
      // one of these never reaches the monomorphizer (ADR-0052). These are
      // generic FUNCTIONS in the prelude only so that one declaration covers
      // every width; there is no body to specialize, and queueing a
      // specialization of one would emit a symbol for a function that has no
      // machine representation.
      if (target.isStatic &&
          target.enclosingClass?.name == 'Atomic' &&
          target.enclosingLibrary.importUri == preludeUri) {
        return _lowerAtomic(expr, target.name.text);
      }

      // (ADR-0058) `Heap.allocate(n)` -- runtime-sized raw allocation. Same
      // recognition shape as `Atomic.*`: static + enclosing class + prelude
      // URI. `Heap.free` is void-returning and is handled in
      // `_lowerStatement`, the same split as `Port.outb`/`Port.inb`.
      if (target.isStatic &&
          target.name.text == 'allocate' &&
          target.enclosingClass?.name == 'Heap' &&
          target.enclosingLibrary.importUri == preludeUri) {
        final args = expr.arguments.positional;
        if (args.length != 1) {
          throw DccLowerError(
            '"$context": Heap.allocate takes exactly one argument (a byte '
            'count)',
          );
        }
        final size = _lowerExpression(args.single);
        if (size.type != DCInt.u64) {
          throw DccLowerError(
            '"$context": Heap.allocate takes a u64 byte count, got '
            '${size.type}',
          );
        }
        final dest = DCValue(_allocId(), const DCPointer(DCInt.u8));
        _addInstr(AllocRaw(dest: dest, sizeBytes: size));
        return dest;
      }

      // `Rodata.addressOf(table)` (ADR-0040) -- a plain static method call,
      // recognized the same way `Port.inb` is: static + enclosing class name
      // + prelude URI. Its argument must be a StaticGet naming a @rodata
      // field; anything else cannot have an address.
      if (target.isStatic &&
          target.name.text == 'addressOf' &&
          (target.enclosingClass?.name == 'Rodata' ||
              target.enclosingClass?.name == 'Bss') &&
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
      // (ADR-0055) `Str("literal")`, `s.length`, `s.bytes`. Same
      // extension-type call shapes the sized ints use -- `Str|constructor#`
      // and `Str|get#length` -- so they are recognized the same way.
      if (target.isExtensionTypeMember &&
          target.enclosingLibrary.importUri == preludeUri) {
        final name = target.name.text;
        if (name == 'Str|constructor#') {
          final arg = expr.arguments.positional.single;
          if (arg is! StringLiteral) {
            throw DccLowerError(
              '"$context": Str(...) needs a string LITERAL. Its bytes are '
              'emitted into .rodata at compile time, so a runtime string has '
              'nothing to point at (ADR-0053).',
            );
          }
          return _lowerStringLiteral(arg.value);
        }
        if (name == 'Str|get#length' || name == 'Str|get#address') {
          final receiver = _lowerExpression(expr.arguments.positional.single);
          if (receiver.type != strStructType) {
            throw DccLowerError(
              '"$context": ${name.split('#').last} read on ${receiver.type}, '
              'expected a Str',
            );
          }
          if (name == 'Str|get#length') {
            final dest = DCValue(_allocId(), DCInt.u64);
            _addInstr(ExtractField(dest: dest, struct: receiver, fieldIndex: 1));
            return dest;
          }
          // `.address` -- the struct holds a real `ptr` so the C ABI sees
          // `{char*, size_t}`, but the surface hands back a u64 so ordinary
          // pointer arithmetic works (ADR-0053).
          final ptr = DCValue(_allocId(), const DCPointer(DCInt.u8));
          _addInstr(ExtractField(dest: ptr, struct: receiver, fieldIndex: 0));
          final dest = DCValue(_allocId(), DCInt.u64);
          _addInstr(PtrToInt(dest: dest, pointer: ptr));
          return dest;
        }
      }

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

        // `f64(1.5)` / `f32(0.5)` -- constructing a float literal
        // (ADR-0065), the same implicit-constructor shape as the sized
        // ints ("<width>|constructor#"). Only compile-time-constant
        // arguments are handled, same rule as the sized ints -- and
        // `f64(2)` works too: an INTEGER literal in a double-typed
        // parameter position is turned into a DoubleLiteral by the CFE
        // before lowering ever sees it (verified empirically, like every
        // other Kernel-shape claim in this file).
        final floatLitType = switch (target.name.text) {
          'f32|constructor#' => DCFloat.f32,
          'f64|constructor#' => DCFloat.f64,
          _ => null,
        };
        if (floatLitType != null) {
          final arg = expr.arguments.positional.single;
          final folded = _tryFoldConstDouble(arg);
          if (folded == null) {
            throw DccLowerError(
              '"$context": a $floatLitType literal constructed from a '
              'non-constant expression $arg (${arg.runtimeType}) — the '
              'argument must be a double literal or a compile-time double '
              'constant',
            );
          }
          // An f32 dest stores the full double here; the single
          // round-to-nearest-even to binary32 happens once, at emission
          // (ConstFloat's doc comment).
          final dest = DCValue(_allocId(), floatLitType);
          _addInstr(ConstFloat(dest: dest, value: folded));
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
        // (ADR-0054) A constructor invocation names its own type arguments
        // directly -- `Box<u64>(v)` -- so this is the one discovery site that
        // needs no receiver at all.
        final inst = _instanceFromArgs(enclosingClass, expr.arguments.types);
        if (inst == null) {
          throw DccLowerError(
            '"$context": cannot instantiate "${enclosingClass.name}" with '
            '${expr.arguments.types.length} type arguments; it declares '
            '${enclosingClass.typeParameters.length} '
            '(docs/decisions/0054-generic-classes.md)',
          );
        }
        return _lowerHeapConstruction(expr, inst);
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

      // (ADR-0058) `p.address` -- the inverse of `Pointer.fromAddress`,
      // which has existed since M1 while this did not: a pointer could be
      // made from an address but never turned back into one. Needed the
      // moment raw byte buffers appeared, since indexing one means
      // `fromAddress(p.address + i)` until `elementAt` lands (GAP-0051).
      if (target.name.text == 'address' &&
          target.enclosingClass?.name == 'Pointer' &&
          target.enclosingLibrary.importUri == preludeUri) {
        final receiver = _lowerExpression(expr.receiver);
        if (receiver.type is! DCPointer) {
          throw DccLowerError(
            '"$context": .address read on ${receiver.type}, expected a '
            'Pointer',
          );
        }
        final dest = DCValue(_allocId(), DCInt.u64);
        _addInstr(PtrToInt(dest: dest, pointer: receiver));
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
        return _lowerHeapFieldLoad(
            expr,
            _instanceOfReceiver(expr.receiver, enclosingClass,
                'the field read "${expr.interfaceTarget.name.text}"'));
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
        // (ADR-0054, GAP-0055) A method with its own type parameters would
        // need one body per (class instantiation x method type arguments)
        // pair. Refused here, by name: without this the failure surfaces as
        // ADR-0052's "type parameter has no binding ... which is a dcc-lower
        // bug", which is both confusing and wrong -- this is an unimplemented
        // shape, not a broken invariant.
        if (target.function.typeParameters.isNotEmpty) {
          throw DccLowerError(
            '"$context": "${enclosing.name}.${target.name.text}" is a GENERIC '
            'METHOD. Generic classes are monomorphized (ADR-0054) and generic '
            'top-level functions are (ADR-0052), but a generic method on a '
            'class is neither and is not implemented — see '
            'docs/known-gaps.md GAP-0055. Make it a generic top-level '
            'function taking the receiver as its first parameter.',
          );
        }

        // (ADR-0054) Which INSTANTIATION's method body this call goes to.
        // Resolved BEFORE the receiver is lowered, so a failure names the
        // call rather than surfacing later as a missing symbol.
        final inst = _instanceOfReceiver(
            expr.receiver, enclosing, 'the call to "${target.name.text}"');
        final receiver = _lowerExpression(expr.receiver);
        final args = <DCValue>[receiver];
        for (final arg in expr.arguments.positional) {
          args.add(_lowerExpression(arg));
        }
        // The callee's return type is written in terms of the RECEIVER's
        // type parameters, not this function's -- `T unwrap()` on
        // `Box<u64>` returns u64 regardless of what `T` means here. Same
        // shape as ADR-0052's `_lowerCalleeType`, one level up: resolve
        // against the callee's own bindings, not the caller's.
        final returnType = _lowerType(
          _substituteType(target.function.returnType, inst.substitution),
          context: '$context call to ${target.name.text}',
        );
        final dest = DCValue(_allocId(), returnType);
        _addInstr(Call(
          dest: dest,
          targetName: methodLinkName(inst.mangledName, target.name.text),
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

  /// A string literal -> a `Str` slice over bytes in `.rodata` (ADR-0055).
  ///
  /// Interned by CONTENT: two identical literals share one global. They are
  /// immutable and non-owning, so nothing can distinguish them, and merging
  /// is unambiguously right here -- unlike ADR-0040's descriptors, where two
  /// byte-identical globals must stay distinct because their ADDRESS is their
  /// identity.
  ///
  /// `length` is the UTF-8 BYTE count, not Dart's UTF-16 code-unit count.
  /// Spec §7 names that as the largest single source of semantic drift from
  /// upstream Dart.
  DCValue _lowerStringLiteral(String content) {
    final bytes = utf8.encode(content);
    final symbol = stringLiterals.putIfAbsent(
      content,
      () => 'dc.str.${stringLiterals.length}',
    );

    final address = DCValue(_allocId(), DCInt.u64);
    _addInstr(AddressOfGlobal(dest: address, globalName: symbol));
    final pointer = DCValue(_allocId(), const DCPointer(DCInt.u8));
    _addInstr(IntToPtr(dest: pointer, address: address));
    final length = DCValue(_allocId(), DCInt.u64);
    _addInstr(ConstInt(dest: length, bits: bytes.length));

    final dest = DCValue(_allocId(), strStructType);
    _addInstr(MakeStruct(
      dest: dest,
      structType: strStructType,
      fields: [pointer, length],
    ));
    return dest;
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

  /// Lowers the shared first argument of every `Atomic.*` call: the
  /// `Pointer<T>` being operated on. Returns the lowered pointer and the
  /// element type read off it.
  ///
  /// The ELEMENT TYPE IS THE WIDTH, and it comes from the pointer rather than
  /// from the method name (`fetchAdd32`, `fetchAdd64`, …) on purpose. It is
  /// the same information `Pointer<T>.value` already uses to pick a load
  /// width, so there is one place that decides it and no way for a call site
  /// to restate it wrongly — the failure mode GAP-0051 describes for the
  /// hand-written `u64(8)` strides.
  (DCValue, DCType) _lowerAtomicPointerArg(StaticInvocation expr, String name) {
    final args = expr.arguments.positional;
    if (args.isEmpty) {
      throw DccLowerError(
        '"$context": Atomic.$name needs a Pointer<T> as its first argument',
      );
    }
    final pointer = _lowerExpression(args.first);
    final pointerType = pointer.type;
    if (pointerType is! DCPointer) {
      throw DccLowerError(
        '"$context": Atomic.$name\'s first argument has type $pointerType, '
        'expected a Pointer<T>. Compose one with '
        '`Pointer<uN>.fromAddress(Bss.addressOf(x))`.',
      );
    }
    final element = pointerType.pointee;
    if (element is! DCInt) {
      throw DccLowerError(
        '"$context": Atomic.$name on a Pointer<$element>. An atomic operand '
        'must be a sized integer (u8/u16/u32/u64) — anything else lowers to a '
        '`__atomic_*` libcall, which is an undefined runtime symbol in a '
        '`@bare` object and a CLAUDE.md rule 1 violation.',
      );
    }
    return (pointer, element);
  }

  /// (ADR-0055) Every value-producing `Atomic.*` member. `Atomic.store` is
  /// void and handled in `_lowerStatement`.
  DCValue _lowerAtomic(StaticInvocation expr, String name) {
    final (pointer, elementType) = _lowerAtomicPointerArg(expr, name);
    final args = expr.arguments.positional;

    if (name == 'load') {
      if (args.length != 1) {
        throw DccLowerError(
          '"$context": Atomic.load takes exactly one argument, the pointer',
        );
      }
      final dest = DCValue(_allocId(), elementType);
      _addInstr(AtomicLoad(dest: dest, pointer: pointer));
      return dest;
    }

    // Names map to DC-IR's AtomicOp, which in turn carries LLVM's own opcode
    // names, so there is exactly one translation in the whole pipeline and it
    // is this table.
    final op = switch (name) {
      'exchange' => AtomicOp.xchg,
      'fetchAdd' => AtomicOp.add,
      'fetchSub' => AtomicOp.sub,
      'fetchAnd' => AtomicOp.and,
      'fetchOr' => AtomicOp.or,
      'fetchXor' => AtomicOp.xor,
      _ => null,
    };
    if (op == null) {
      throw DccLowerError(
        '"$context": Atomic.$name is not implemented. Available: load, store, '
        'exchange, fetchAdd, fetchSub, fetchAnd, fetchOr, fetchXor. '
        'Compare-exchange is deliberately absent — see docs/known-gaps.md '
        'GAP-0041.',
      );
    }
    if (args.length != 2) {
      throw DccLowerError(
        '"$context": Atomic.$name takes a pointer and a value',
      );
    }
    final value = _lowerExpression(args[1]);
    if (value.type != elementType) {
      throw DccLowerError(
        '"$context": Atomic.$name applies a ${value.type} to a '
        'Pointer<$elementType>. The widths must match exactly — there is no '
        'implicit widening (spec §4.1).',
      );
    }
    final dest = DCValue(_allocId(), elementType);
    _addInstr(AtomicRmw(dest: dest, pointer: pointer, op: op, value: value));
    return dest;
  }

  /// (ADR-0056) Reads the `Ordering` argument of a `fence(...)` call.
  ///
  /// `Ordering.release` does NOT arrive as a `StaticGet` naming a field: a
  /// `const` field's references are inlined by the CFE at every use site
  /// (ADR-0040's central finding), so what arrives is a `ConstantExpression`
  /// wrapping an `InstanceConstant` of class `Ordering`. Its one field holds
  /// the ordering's own NAME as a `StringConstant` — carrying a name rather
  /// than an index, again ADR-0040's lesson, and it means a malformed call
  /// produces an error naming the ordering rather than an integer.
  DCOrdering _lowerOrdering(Expression argument) {
    Constant? constant;
    if (argument is ConstantExpression) {
      constant = argument.constant;
    }
    if (constant is! InstanceConstant ||
        constant.classNode.name != 'Ordering') {
      throw DccLowerError(
        '"$context": fence\'s argument must be one of the `Ordering` '
        'constants — `Ordering.acquire`, `.release`, `.acqRel`, `.seqCst` or '
        '`.compilerOnly`. Got ${argument.runtimeType}. It cannot be a '
        'variable: the ordering decides which instruction is emitted, so it '
        'has to be known at compile time.',
      );
    }
    final values = constant.fieldValues.values.toList();
    final nameConstant = values.length == 1 ? values.single : null;
    if (nameConstant is! StringConstant) {
      throw DccLowerError(
        '"$context": an `Ordering` constant must hold exactly one constant '
        'string naming itself (prelude `Ordering._(...)`)',
      );
    }
    return switch (nameConstant.value) {
      'acquire' => DCOrdering.acquire,
      'release' => DCOrdering.release,
      'acqRel' => DCOrdering.acqRel,
      'seqCst' => DCOrdering.seqCst,
      'compilerOnly' => DCOrdering.compilerOnly,
      _ => throw DccLowerError(
          '"$context": unknown Ordering "${nameConstant.value}"',
        ),
    };
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
    // (ADR-0065) Floats take the same EqualsCall route as the sized ints —
    // an extension type cannot declare `operator ==` (this method's own
    // header comment) — but lower to FCmp: `==` is IEEE's ordered-equal
    // (`oeq`, false for NaN on either side) and `!=` its complement
    // (`une`, TRUE when unordered — `NaN != NaN` is true), matching
    // upstream Dart's `double` exactly.
    if (lhsType is DCFloat && rhsType is DCFloat) {
      if (lhsType.width != rhsType.width) {
        throw DccLowerError(
          '"$context": ${negated ? '!=' : '=='} between different float '
          'types ($lhsType vs $rhsType). DCDart has no implicit float '
          'conversions — convert one side explicitly (.toF64()/.toF32()).',
        );
      }
      final dest = DCValue(_allocId(), const DCBool());
      _addInstr(FCmp(
        dest: dest,
        predicate: negated ? FCmpPredicate.une : FCmpPredicate.oeq,
        lhs: lhs,
        rhs: rhs,
      ));
      return dest;
    }
    if (lhsType is! DCInt || rhsType is! DCInt) {
      throw DccLowerError(
        '"$context": ${negated ? '!=' : '=='} is only supported between two '
        'sized integers or two floats, got $lhsType and $rhsType',
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

  /// (ADR-0052) Lowers a type appearing in a CALLEE's signature.
  ///
  /// A generic callee's signature mentions its own type parameters, so it
  /// must be resolved against the call site's type arguments rather than
  /// against this function's substitution. Getting this wrong produces
  /// "type parameter T has no binding" at the CALLER, which is a confusing
  /// place to see it.
  DCType _lowerCalleeType(
    DartType type,
    StaticInvocation expr,
    Procedure target, {
    required String context,
  }) {
    final typeParams = target.function.typeParameters;
    if (typeParams.isEmpty) return _lowerType(type, context: context);

    if (typeParams.length != expr.arguments.types.length) {
      throw DccLowerError(
        '"$context": call to generic "${target.name.text}" with '
        '${expr.arguments.types.length} type arguments, expected '
        '${typeParams.length}',
      );
    }

    // (ADR-0052) Build the CALLEE's binding and substitute the whole type
    // through it. The call site's argument may itself be a type parameter,
    // when a generic calls a generic, so each one is resolved through OUR
    // substitution before being handed on.
    //
    // (ADR-0054) This is a full structural substitution rather than the
    // single top-level `TypeParameterType` check it used to be. With generic
    // classes a callee's signature can say `Box<T>` -- not a
    // `TypeParameterType`, so the old check skipped it entirely and passed
    // `Box<T>` down with the callee's `T` unbound. That reached
    // `_lowerSignatureType`, which registered an instantiation of `Box` at a
    // type parameter, and the failure surfaced much later as an
    // "unsupported struct field type TypeParameterType" naming a class the
    // programmer never wrote.
    final calleeSubstitution = <String, DartType>{};
    for (var i = 0; i < typeParams.length; i++) {
      final name = typeParams[i].name;
      if (name == null) continue;
      calleeSubstitution[name] = _resolveTypeParameter(expr.arguments.types[i]);
    }
    final resolved = _substituteType(type, calleeSubstitution);
    if (resolved is TypeParameterType) {
      throw DccLowerError(
        '"$context": could not bind type parameter '
        '"${resolved.parameter.name}" from the call site\'s type arguments',
      );
    }
    return _lowerSignatureType(resolved,
        preludeUri: preludeUri, heapLayouts: heapLayouts, context: context);
  }

  /// (ADR-0052) The link name for a call target, specializing it if generic.
  ///
  /// Queueing happens HERE rather than in a separate discovery pass, because
  /// which specializations exist is only knowable by walking call sites --
  /// and walking them twice (once to discover, once to lower) would mean two
  /// implementations of the same traversal that could disagree.
  String _targetLinkName(StaticInvocation expr, Procedure target) {
    final typeParams = target.function.typeParameters;
    if (typeParams.isEmpty) return target.name.text;

    final typeArgs = expr.arguments.types
        .map(_resolveTypeParameter)
        .toList(growable: false);
    if (typeArgs.length != typeParams.length) {
      throw DccLowerError(
        '"$context": call to generic "${target.name.text}" with '
        '${typeArgs.length} type arguments, expected ${typeParams.length}',
      );
    }
    final mangled = specializationLinkName(target.name.text, typeArgs);
    if (!pendingSpecializations.containsKey(mangled)) {
      pendingSpecializations[mangled] = _Specialization(target, {
        for (var i = 0; i < typeParams.length; i++)
          typeParams[i].name!: typeArgs[i],
      });
    }
    return mangled;
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
    // (ADR-0052) A generic callee's signature mentions ITS type parameters,
    // which the caller's own substitution knows nothing about. Resolve them
    // with the CALL SITE's type arguments instead -- the caller's map is for
    // the caller's own parameters.
    final calleeReturnType = _lowerCalleeType(
      returnType,
      expr,
      target,
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
      final expectedType = _lowerCalleeType(
        calleeParams[i].type,
        expr,
        target,
        context: '"${target.name.text}" param ${calleeParams[i].name} (called from "$context")',
      );
      final arg = _lowerExpression(callArgs[i]);
      if (arg.type != expectedType) {
        throw DccLowerError(
          '"$context": call to "${target.name.text}" passes argument $i of '
          'type ${arg.type} for a parameter declared $expectedType -- no '
          'implicit widening (same rule as arithmetic)'
          '${_funcPtrConventionHint(expectedType, arg.type)}',
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

    _addInstr(Call(
      dest: dest,
      targetName: _targetLinkName(expr, target),
      args: loweredArgs,
      argOwnership: argOwnership,
    ));
  }

  // -------------------------------------------------------------------
  // Non-capturing local functions (ADR-0057).
  //
  // The whole feature is two operations: HOIST a definition to a top-level
  // symbol, and lower a CALL to it as an ordinary direct `Call`. There is no
  // third operation, and that is the point -- a closure that needed a
  // representation as a VALUE would need a DC-IR instruction that does not
  // exist (GAP-0052) and a capture convention that is not a lowering decision
  // (docs/escalations/0008-closure-capture-and-indirect-call-elision.md).
  // -------------------------------------------------------------------

  /// Hoists one local function to a top-level symbol, or rejects it, naming
  /// which of the two open questions it runs into.
  ///
  /// Rejection here is the load-bearing half. Everything this refuses is
  /// refused because implementing it would decide something an implementation
  /// unit does not get to decide -- not because it is hard.
  void _hoistLocalFunction(VariableDeclaration decl, FunctionNode node, String? name) {
    final what = 'local function "${name ?? '<anonymous>'}" in "$context"';

    if (node.typeParameters.isNotEmpty) {
      throw DccLowerError(
        '$what is generic — monomorphization (ADR-0052) discovers '
        'specializations from call sites naming a top-level target, and a '
        'local function has no such name to discover',
      );
    }
    if (node.namedParameters.isNotEmpty ||
        node.requiredParameterCount != node.positionalParameters.length) {
      throw DccLowerError(
        '$what has named or optional parameters — DCDart lowers positional, '
        'required parameters only (the same restriction top-level `@bare` '
        'functions carry)',
      );
    }
    if (node.asyncMarker != AsyncMarker.Sync) {
      throw DccLowerError('$what is ${node.asyncMarker.name}; DCDart has no async or generators');
    }
    final body = node.body;
    if (body == null) {
      throw DccLowerError('$what has no body');
    }

    // Reserved and registered BEFORE the capture scan, so that a body which
    // calls ITSELF sees its own name as a known static symbol rather than as
    // a free variable. Self-recursion is the case that makes the ordering
    // matter (examples/m2-closure/closure.dart shape 4).
    final linkName = hoister.reserve(_emittedLinkName, name);
    _localFunctions[decl] = _LocalFunction(linkName, node);

    final scan = _ClosureScan();
    scan.declared.addAll(node.positionalParameters);
    body.accept(scan);

    if (scan.usesThis) {
      throw DccLowerError(
        '$what reads `this` from the enclosing method — that is a capture. A '
        'captured value needs an environment object, which needs a heap, and '
        'the only heap this project has is ADR-0015\'s module-global arena '
        '(escalation 0002 is still open). See '
        'docs/escalations/0008-closure-capture-and-indirect-call-elision.md',
      );
    }

    for (final used in scan.valueUses) {
      if (scan.declared.contains(used)) continue;
      // (ADR-0060) A sibling (or own) local function's name in VALUE position
      // is NOT a capture, for the same reason it is not one in CALL position:
      // the name resolves to a static SYMBOL, not to a slot in the enclosing
      // frame. It lowers to a `FuncRef`, which needs no environment. ADR-0057
      // had to reject this only because DC-IR had no type for the value to
      // inhabit; it now does, and the free-variable rule generalizes without
      // touching the capture question escalation 0008 §2 still owns.
      if (_localFunctions.containsKey(used)) continue;
      throw DccLowerError(
        '$what captures "${used.name}" from an enclosing scope. Only '
        'NON-CAPTURING local functions are lowered (ADR-0057): a captured '
        'value needs an environment object, which needs a heap, and the only '
        'heap this project has is ADR-0015\'s module-global arena — exactly '
        'what CLAUDE.md rule 1 forbids a `@bare` object to depend on '
        '(escalation 0002, still open). Pass it as a parameter instead. See '
        'docs/escalations/0008-closure-capture-and-indirect-call-elision.md',
      );
    }

    for (final called in scan.callUses) {
      if (scan.declared.contains(called)) continue;
      if (_localFunctions.containsKey(called)) continue;
      throw DccLowerError(
        '$what calls "${called.name}", which is not a local function declared '
        'before it in an enclosing scope. Either it is a function VALUE (no '
        'DC-IR indirect call exists, GAP-0052) or it is a forward reference '
        'to a sibling declared later — move the declaration above this one',
      );
    }

    hoister.pending[linkName] = _HoistedClosure(
      node,
      linkName,
      {..._localFunctions},
      proc,
      typeSubstitution,
    );
  }

  /// A call to a hoisted local function. An ordinary direct `Call` — the
  /// callee's `FunctionNode` is right there, so parameter types are checked
  /// and `argOwnership` is computed EXACTLY, the same way `_lowerCallArgs`
  /// does it for a top-level target.
  ///
  /// That exactness is the reason this subset is worth landing on its own:
  /// dc-elide's pass-4 call-consumed case (ADR-0031) fires through a call to
  /// a non-capturing closure exactly as it does through any other call, so
  /// `examples/m2-closure`'s `viaTopLevel`/`viaClosure` pair emits identical
  /// ARC counts. Nothing about that survives a call through a VALUE, where
  /// the callee is unknown and ownership is not conservatively derivable at
  /// all — see docs/escalations/0008.
  ///
  /// Deliberately NOT shared with `_lowerCallArgs`: that path is threaded
  /// through `StaticInvocation`/`Procedure` for `@extern` manifest checks and
  /// generic type-argument resolution (`_lowerCalleeType`), neither of which
  /// can apply here. Merging them would mean parameterizing every one of
  /// those steps on "is this really a Procedure", which is more code, not
  /// less.
  DCValue? _lowerLocalCall(
    _LocalFunction callee,
    Arguments arguments, {
    required bool allowVoid,
  }) {
    final calleeFn = callee.node;
    if (arguments.named.isNotEmpty || arguments.types.isNotEmpty) {
      throw DccLowerError(
        '"$context": call to local function "${callee.linkName}" passes named '
        'or type arguments; neither is lowered',
      );
    }
    final calleeParams = calleeFn.positionalParameters;
    final callArgs = arguments.positional;
    if (calleeParams.length != callArgs.length) {
      throw DccLowerError(
        '"$context": call to local function "${callee.linkName}" passes '
        '${callArgs.length} arguments, but it takes ${calleeParams.length}',
      );
    }

    final returnType = calleeFn.returnType;
    DCValue? dest;
    if (returnType is VoidType) {
      if (!allowVoid) {
        throw DccLowerError(
          '"$context": local function "${callee.linkName}" returns void — a '
          'void call has no value, so it cannot appear inside an expression',
        );
      }
    } else {
      dest = DCValue(
        _allocId(),
        _lowerType(returnType,
            context: '"${callee.linkName}" return type (called from "$context")'),
      );
    }

    final loweredArgs = <DCValue>[];
    final argOwnership = <bool>[];
    for (var i = 0; i < calleeParams.length; i++) {
      final expectedType = _lowerType(
        calleeParams[i].type,
        context: '"${callee.linkName}" param ${calleeParams[i].name} '
            '(called from "$context")',
      );
      final arg = _lowerExpression(callArgs[i]);
      if (arg.type != expectedType) {
        throw DccLowerError(
          '"$context": call to local function "${callee.linkName}" passes '
          'argument $i of type ${arg.type} for a parameter declared '
          '$expectedType -- no implicit widening (same rule as arithmetic)'
          '${_funcPtrConventionHint(expectedType, arg.type)}',
        );
      }
      final isOwnedParam =
          _hasMarkerAnnotation(calleeParams[i].annotations, '_Owned', preludeUri);
      if (expectedType is DCHeapPointer && isOwnedParam && !_isFreshHeapOwnership(callArgs[i])) {
        _addInstr(Retain(object: arg));
      }
      if (expectedType is DCWeakPointer && isOwnedParam && !_isFreshHeapOwnership(callArgs[i])) {
        throw DccLowerError(
          '"$context": call to local function "${callee.linkName}" passes an '
          'existing Weak<T> local to an @owned Weak<T> parameter -- only a '
          'fresh Weak.fromStrong(...) construction or a call returning '
          'Weak<T> can be passed directly (same restriction as ADR-0023)',
        );
      }
      argOwnership.add(expectedType is DCHeapPointer && isOwnedParam);
      loweredArgs.add(arg);
    }

    _addInstr(Call(
      dest: dest,
      targetName: callee.linkName,
      args: loweredArgs,
      argOwnership: argOwnership,
    ));
    return dest;
  }

  // -------------------------------------------------------------------
  // Function pointers and indirect calls (ADR-0060).
  //
  // Three operations, and the middle one is the whole design:
  //   1. TEAR OFF  -- `FuncRef`, turning a named function into a value whose
  //                   `DCFuncPtr` type records its ARC convention EXACTLY,
  //                   because the declaration is right there.
  //   2. CARRY     -- ordinary DCType equality, so the convention travels
  //                   with the value through locals, parameters and returns
  //                   and cannot be lost or silently widened.
  //   3. CALL      -- `IndirectCall`, which reads ownership back off the
  //                   pointer's type instead of being told it.
  //
  // Step 2 is why an indirect call is not an elision barrier here. See
  // docs/escalations/0008 §3 for what the alternative costs.
  // -------------------------------------------------------------------

  /// The `DCFuncPtr` type of the function [node] declares, with per-parameter
  /// ownership read from its `@owned` annotations.
  ///
  /// This is the ONLY place a `DCFuncPtr` is built from a declaration, and so
  /// the only place ownership can be known exactly. `_lowerType`'s
  /// `FunctionType` case builds the all-borrowed one from a Dart function
  /// type, which carries no annotations to read — see the comment there.
  DCFuncPtr _funcPtrTypeOfNode(FunctionNode node, {required String what}) {
    if (node.typeParameters.isNotEmpty) {
      throw DccLowerError(
        '"$context": $what is generic, so it has no single machine '
        'representation and no one address to take (ADR-0052)',
      );
    }
    if (node.namedParameters.isNotEmpty ||
        node.requiredParameterCount != node.positionalParameters.length) {
      throw DccLowerError(
        '"$context": $what has named or optional parameters; DCDart lowers '
        'positional, required parameters only',
      );
    }
    final params = <DCFuncParam>[];
    for (final p in node.positionalParameters) {
      final type = _lowerType(p.type, context: '$what param ${p.name}');
      final isOwned = _hasMarkerAnnotation(p.annotations, '_Owned', preludeUri);
      if (type is DCWeakPointer && isOwned) {
        // (ADR-0023) A direct call to such a function is already restricted to
        // a FRESH `Weak<T>` argument, a check that needs the argument
        // EXPRESSION. Through a pointer there is no callee declaration at the
        // call site to re-derive that restriction from, and `DCFuncParam.owned`
        // deliberately mirrors `Call.argOwnership`, which does not track weak
        // ownership at all. Refused at the tear-off, where the signature can
        // still be named, rather than lowered into something that silently
        // skips the check.
        throw DccLowerError(
          '"$context": $what takes an `@owned Weak<T>` parameter, which cannot '
          'be reached through a function pointer — weak-count ownership has no '
          'representation in `DCFuncPtr` (docs/known-gaps.md GAP-0057)',
        );
      }
      // `owned` mirrors `Call.argOwnership` EXACTLY: true only for a
      // DCHeapPointer parameter annotated `@owned`. `@owned` on a scalar is
      // ignored in both places -- there is no ARC traffic to elide.
      params.add(DCFuncParam(type, owned: type is DCHeapPointer && isOwned));
    }
    final returnType = node.returnType;
    return DCFuncPtr(
      params,
      returnType is VoidType
          ? const DCVoid()
          : _lowerType(returnType, context: '$what return type'),
    );
  }

  /// Emits a `FuncRef` for [linkName] with the signature [node] declares, and
  /// returns the resulting function-pointer value.
  DCValue _lowerFuncRef(String linkName, FunctionNode node, {required String what}) {
    final dest = DCValue(_allocId(), _funcPtrTypeOfNode(node, what: what));
    _addInstr(FuncRef(dest: dest, targetName: linkName));
    return dest;
  }

  /// `final f = topLevelFn;` — Kernel's `StaticTearOff`.
  ///
  /// Restricted to a `@bare` top-level procedure, and both halves of that
  /// matter. A GENERIC one is refused by `_funcPtrTypeOfNode` (a template has
  /// no address). An `@extern` C symbol is refused here: its ARC convention is
  /// whatever the C author decided, and nothing in this compiler can check
  /// that a C function releases a `@owned` argument — so the `DCFuncPtr` type
  /// this would produce would be an assertion, not a derivation, which is
  /// precisely what ADR-0060 is built to avoid.
  DCValue _lowerStaticTearOff(Procedure target) {
    final name = target.name.text;
    if (!_hasMarkerAnnotation(target.annotations, '_Bare', preludeUri)) {
      throw DccLowerError(
        '"$context": "$name" is torn off as a function pointer but is not '
        '`@bare`. Only a `@bare` top-level function has a signature whose ARC '
        'convention this compiler derived rather than assumed; an `@extern` C '
        'symbol\'s convention is unverifiable from here '
        '(docs/known-gaps.md GAP-0059)',
      );
    }
    if (target.isExternal) {
      throw DccLowerError(
        '"$context": "$name" is torn off as a function pointer but has no '
        'body in this unit',
      );
    }
    return _lowerFuncRef(name, target.function, what: 'function "$name"');
  }

  /// A call through a function-pointer VALUE (ADR-0060) — the counterpart of
  /// [_lowerLocalCall] and [_lowerCallArgs] for a callee that is an operand
  /// rather than a name.
  ///
  /// The argument path is deliberately IDENTICAL in shape to those two,
  /// including the `@owned` caller-side `Retain`, and it can be: everything
  /// those read from the callee's `FunctionNode` is read here from
  /// `callee.type`'s `DCFuncPtr` instead. That is the claim ADR-0060 makes
  /// concrete — an indirect call site is not less informed than a direct one,
  /// it is informed by a different carrier.
  DCValue? _lowerIndirectCall(
    DCValue callee,
    Arguments arguments, {
    required bool allowVoid,
    required String what,
  }) {
    final signature = callee.type;
    if (signature is! DCFuncPtr) {
      throw DccLowerError(
        '"$context": $what is called, but its type is $signature, not a '
        'function pointer',
      );
    }
    if (arguments.named.isNotEmpty || arguments.types.isNotEmpty) {
      throw DccLowerError(
        '"$context": call through $what passes named or type arguments; '
        'neither is lowered',
      );
    }
    final callArgs = arguments.positional;
    if (signature.params.length != callArgs.length) {
      throw DccLowerError(
        '"$context": call through $what passes ${callArgs.length} arguments, '
        'but its type takes ${signature.params.length}',
      );
    }

    DCValue? dest;
    final returnType = signature.returnType;
    if (returnType is DCVoid) {
      if (!allowVoid) {
        throw DccLowerError(
          '"$context": $what returns void — a void call has no value, so it '
          'cannot appear inside an expression',
        );
      }
    } else {
      dest = DCValue(_allocId(), returnType);
    }

    final loweredArgs = <DCValue>[];
    for (var i = 0; i < signature.params.length; i++) {
      final expected = signature.params[i];
      final arg = _lowerExpression(callArgs[i]);
      if (arg.type != expected.type) {
        throw DccLowerError(
          '"$context": call through $what passes argument $i of type '
          '${arg.type} for a parameter typed ${expected.type} -- no implicit '
          'widening (same rule as arithmetic)'
          '${_funcPtrConventionHint(expected.type, arg.type)}',
        );
      }
      // The `@owned` retain, read off the POINTER's type. `_lowerCallArgs`
      // reads the same fact off the callee's annotation list; there is no
      // third possibility and no conservative fallback -- if this were
      // unknown, the retain could be neither emitted nor omitted correctly.
      if (expected.owned && !_isFreshHeapOwnership(callArgs[i])) {
        _addInstr(Retain(object: arg));
      }
      loweredArgs.add(arg);
    }

    // No `argOwnership` argument: `IndirectCall` derives it from
    // `callee.type`, which is the same `signature` the loop above just
    // checked every argument against. dc-elide therefore sees exactly the
    // ownership this lowering acted on, with no second copy to disagree.
    _addInstr(IndirectCall(dest: dest, callee: callee, args: loweredArgs));
    return dest;
  }

  /// Lowers the callee of a `FunctionInvocation` that is NOT a call to a
  /// hoisted local function (`_calleeOf` returned null), i.e. a call through a
  /// value.
  ///
  /// The receiver is lowered unconditionally, before its type is known to be a
  /// function pointer. That is safe rather than sloppy: if it turns out not to
  /// be one, `_lowerIndirectCall` throws and no DC-IR is kept — a
  /// `DccLowerError` aborts the whole compilation, so there is no path on
  /// which the instructions emitted here reach the backend.
  DCValue _lowerCalleeValue(FunctionInvocation expr) =>
      _lowerExpression(expr.receiver);

  /// The hoisted local function a call expression names, or null if the
  /// expression is not a call to one.
  _LocalFunction? _calleeOf(Expression expr) {
    if (expr is LocalFunctionInvocation) return _localFunctions[expr.variable];
    if (expr is FunctionInvocation) {
      final receiver = expr.receiver;
      if (receiver is VariableGet) return _localFunctions[receiver.variable];
    }
    return null;
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
  DCValue _lowerHeapConstruction(ConstructorInvocation expr, _ClassInstance inst) {
    final heapClass = inst.cls;
    // (ADR-0054) Layout, payload size and destructor are all read off the
    // INSTANTIATION. `Box<u64>` and `Box<Node>` happen to agree on payload
    // size here and disagree on all three of field type, destructor and ARC
    // shape -- which is why keying any of this on the class, or on the size,
    // silently produces a leak or a released integer.
    final fields = heapLayouts.layoutFor(inst);
    final payloadSize = heapLayouts.payloadSizeBytes(inst);

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
        destructorName: heapLayouts.destructorNameFor(inst),
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
  DCValue _lowerHeapFieldLoad(InstanceGet expr, _ClassInstance inst) {
    final field = _findHeapField(inst, expr.interfaceTarget.name.text);
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
  void _lowerHeapFieldStore(InstanceSet expr, _ClassInstance inst) {
    final field = _findHeapField(inst, expr.interfaceTarget.name.text);
    if (field.type is DCWeakPointer) {
      throw DccLowerError(
        '"$context": storing to the weak field '
        '"${inst.mangledName}.${field.name}" is not supported. The strong-field '
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
        '"${inst.mangledName}.${field.name}", declared ${field.type} -- no '
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

  _StructField _findHeapField(_ClassInstance inst, String name) {
    final fields = heapLayouts.layoutFor(inst);
    for (final field in fields) {
      if (field.name == name) return field;
    }
    throw DccLowerError(
      '"$context": "${inst.mangledName}" has no field "$name" — this should '
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
  DCType _lowerType(DartType type, {required String context}) {
    // (ADR-0052) Inside a specialization, `T` resolves to the concrete type
    // it was specialized at. This is the ONLY place monomorphization has to
    // touch: once `T` is a real type here, every downstream pass sees an
    // ordinary function and needs no knowledge of generics at all.
    final resolved = _resolveTypeParameter(type);
    return _lowerSignatureType(resolved,
        preludeUri: preludeUri, heapLayouts: heapLayouts, context: context);
  }

  DartType _resolveTypeParameter(DartType type) {
    if (type is TypeParameterType) {
      final concrete = typeSubstitution[type.parameter.name];
      if (concrete == null) {
        throw DccLowerError(
          '"$context": type parameter "${type.parameter.name}" has no '
          'binding. A generic function is only lowered as a specialization '
          'reached from a call site (ADR-0052); this one was reached some '
          'other way, which is a dcc-lower bug.',
        );
      }
      return concrete;
    }
    // (ADR-0054) `Box<T>` -- a type parameter NESTED inside a type argument
    // rather than standing alone. ADR-0052 never had to handle this, because
    // with no generic classes there was no generic type to nest a parameter
    // inside; substitution is structural from here on.
    return _substituteType(type, typeSubstitution);
  }

  /// (ADR-0054) Which INSTANTIATION of [declared] a receiver expression
  /// denotes — `Box<u64>` rather than `Box`.
  ///
  /// A NON-generic class takes the first branch and never reaches the
  /// resolution below, so every shape that predates generic classes behaves
  /// exactly as it did.
  ///
  /// For a generic class the type arguments have to come from the receiver's
  /// STATIC TYPE, which Kernel does not record on the access node:
  /// `InstanceGet`/`InstanceInvocation` carry an interface target whose
  /// enclosing class is the template. It is recovered structurally from the
  /// receiver expression rather than through a `StaticTypeContext`, and that
  /// is deliberate: building one needs `CoreTypes`/`ClassHierarchy` over a
  /// component compiled `--no-link-platform`, where `dart:core` is not
  /// linked at all (kernel_frontend.dart). It is the same reason
  /// `_lowerSignatureType` inspects `.classNode` directly instead of asking
  /// a type environment anything.
  ///
  /// Anything it cannot resolve throws by name. Guessing here would pick a
  /// wrong field layout AND a wrong destructor, and the leak that follows is
  /// silent.
  _ClassInstance _instanceOfReceiver(Expression receiver, Class declared, String what) {
    if (declared.typeParameters.isEmpty) {
      return heapLayouts.instanceOfNonGeneric(declared, context: context);
    }
    final resolved = _receiverInstanceOrNull(receiver);
    if (resolved == null) {
      throw DccLowerError(
        '"$context": could not determine which instantiation of the generic '
        'class "${declared.name}" $what applies to. The receiver is a '
        '${receiver.runtimeType}, and dcc-lower recovers type arguments from '
        'the receiver expression itself (a local, `this`, a constructor call, '
        'a field read or a method result). Bind it to a local with an '
        'explicit type first (docs/decisions/0054-generic-classes.md).',
      );
    }
    return resolved;
  }

  _ClassInstance? _receiverInstanceOrNull(Expression receiver) {
    if (receiver is ThisExpression) return receiverInstance;
    if (receiver is VariableGet) return _instanceFromType(receiver.variable.type);
    if (receiver is ConstructorInvocation) {
      return _instanceFromArgs(
          receiver.target.enclosingClass, receiver.arguments.types);
    }
    if (receiver is InstanceGet) {
      final owner = _ownerInstanceOf(receiver.interfaceTarget, receiver.receiver);
      if (owner == null) return null;
      for (final field in heapLayouts.layoutFor(owner)) {
        if (field.name == receiver.interfaceTarget.name.text) return field.heapFieldInstance;
      }
      return null;
    }
    if (receiver is InstanceInvocation) {
      final target = receiver.interfaceTarget;
      final owner = _ownerInstanceOf(target, receiver.receiver);
      if (owner == null) return null;
      // The method's return type is written in terms of the OWNER's type
      // parameters, so it resolves against the owner's substitution -- the
      // class-level twin of ADR-0052's `_lowerCalleeType` problem.
      return _instanceFromType(_substituteType(target.function.returnType, owner.substitution));
    }
    return null;
  }

  _ClassInstance? _ownerInstanceOf(Member target, Expression receiver) {
    final owner = target.enclosingClass;
    if (owner == null) return null;
    if (owner.typeParameters.isEmpty) return _ClassInstance(owner, const []);
    return _receiverInstanceOrNull(receiver);
  }

  _ClassInstance? _instanceFromType(DartType type) {
    final resolved = _substituteType(type, typeSubstitution);
    if (resolved is! InterfaceType) return null;
    if (!heapLayouts.extendsHeapObject(resolved.classNode)) return null;
    return _instanceFromArgs(resolved.classNode, resolved.typeArguments);
  }

  _ClassInstance? _instanceFromArgs(Class cls, List<DartType> typeArgs) {
    if (!heapLayouts.extendsHeapObject(cls)) return null;
    if (cls.typeParameters.isEmpty) return heapLayouts.register(_ClassInstance(cls, const []));
    if (typeArgs.length != cls.typeParameters.length) return null;
    final resolved = [
      for (final arg in typeArgs) _substituteType(arg, typeSubstitution),
    ];
    for (final arg in resolved) {
      // An unresolved `T` means this was reached from the TEMPLATE rather
      // than from a specialization, which is a dcc-lower bug rather than a
      // source error -- say so instead of registering an instantiation whose
      // layout depends on a type nobody has bound.
      if (arg is TypeParameterType) {
        throw DccLowerError(
          '"$context": instantiating "${cls.name}" at unbound type parameter '
          '"${arg.parameter.name}". A generic class is only lowered as an '
          'instantiation reached from a use site '
          '(docs/decisions/0054-generic-classes.md); this one was reached '
          'some other way, which is a dcc-lower bug.',
        );
      }
    }
    return heapLayouts.register(_ClassInstance(cls, resolved));
  }
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
          // (ADR-0065) The float pair, same extension-type mechanism as the
          // sized ints. This one mapping is what makes `f32`/`f64`
          // parameters, returns AND `Pointer<f32>`/`Pointer<f64>` work —
          // the pointee type routes through here too
          // (_pointeeTypeFromTypeArgs -> _lowerType).
          case 'f32':
            return DCFloat.f32;
          case 'f64':
            return DCFloat.f64;
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
        // (ADR-0054) A `Box<u64>` parameter or return type makes that
        // instantiation reachable even where no constructor for it appears
        // in this unit -- a function that only ever RECEIVES one still needs
        // its methods and destructor to exist. Registering here is what
        // makes "reached by a signature" a discovery site, alongside
        // ADR-0052's call sites.
        //
        // The lowered type itself is unchanged and deliberately so: the
        // pointee is still the `DCVoid()` placeholder (GAP-0003), because
        // layout is resolved from the ACCESS site's class instantiation, not
        // from the DCValue's type. Generic classes therefore add no new
        // information to DC-IR and no new work for the backend, `dc-elide`
        // or `dc-objdump` — the same property ADR-0052 traded on.
        if (cls.typeParameters.isNotEmpty) {
          heapLayouts.register(_ClassInstance(cls, type.typeArguments));
        }
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
    // (ADR-0060) A FUNCTION type in a signature -- a parameter, return type or
    // field holding a callback as a VALUE. Lowers to `DCFuncPtr`.
    //
    // OWNERSHIP IS ALL-BORROWED HERE, AND THAT IS NOT A DEFAULT CHOSEN FOR
    // CONVENIENCE -- it is the only thing a Dart `FunctionType` says. Kernel's
    // `FunctionType.positionalParameters` is a `List<DartType>`; annotations
    // live on `VariableDeclaration`s, which a function TYPE has none of, so
    // `@owned` is not expressible in `u64 Function(Box)` and there is nothing
    // to read. The exact convention is read at the `FuncRef` instead
    // (`_funcPtrTypeOfNode`), where the target's declaration is in hand.
    //
    // The consequence, stated where it will be hit: a function pointer whose
    // callee CONSUMES a heap argument has a `DCFuncPtr` type that is not equal
    // to the one written here, so it cannot be passed to a parameter declared
    // with an ordinary Dart function type. That is a real restriction, filed
    // as GAP-0057, and it is deliberately a hard type error rather than a
    // silent coercion -- see `DCFuncPtr`'s "no variance" note for why either
    // direction of coercion is a double-release or a leak.
    if (type is FunctionType) {
      if (type.namedParameters.isNotEmpty ||
          type.requiredParameterCount != type.positionalParameters.length) {
        throw DccLowerError(
          '"$context": function type ($type) has named or optional parameters; '
          'DCDart lowers positional, required parameters only',
        );
      }
      if (type.typeParameters.isNotEmpty) {
        throw DccLowerError(
          '"$context": function type ($type) is generic. A generic function '
          'has no single machine representation, so there is no one pointer '
          'it could be (ADR-0052\'s reasoning, applied to a value)',
        );
      }
      DCType sub(DartType t, String what) => _lowerSignatureType(
            t,
            preludeUri: preludeUri,
            heapLayouts: heapLayouts,
            context: '$context $what',
          );
      final returnType = type.returnType;
      return DCFuncPtr(
        [
          for (final p in type.positionalParameters)
            DCFuncParam(sub(p, 'parameter'), owned: false),
        ],
        returnType is VoidType ? const DCVoid() : sub(returnType, 'return type'),
      );
    }
    throw DccLowerError(
      '"$context": unsupported type $type (${type.runtimeType}) — dcc-lower '
      'only understands u8/u32/u64/f32/f64/Result/HeapObject subclasses/'
      'Weak<T> from the DCDart prelude so far, see core/dcc-lower/README.md',
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

/// Builds a mutable zero-initialized global from a `@bss` field (ADR-0051).
///
/// THE RESTRICTION IS THE JUSTIFICATION, so it is enforced here rather than
/// documented. A `@bss` block is raw bytes — it may not hold a `HeapObject`
/// or `Weak<T>` reference, because a global holding an ARC-managed reference
/// becomes an ARC root and needs retain/release semantics, a defined lifetime
/// and thread-safety, which are `DCDART_SPEC.md` §3 questions `CLAUDE.md`
/// rule 4 freezes. Restricted to bytes, none of those arise. If this check
/// were a convention rather than code, the frozen decision would get made by
/// accident.
DCGlobal _bssGlobal(Field field) {
  final name = field.name.text;
  if (field.isConst) {
    throw DccLowerError(
      '"$name" is `@bss const`. Mutable storage cannot be `const`; use '
      '`@bss final Bss $name = const Bss(bytes: N);`',
    );
  }
  if (!field.isFinal) {
    throw DccLowerError('"$name" is `@bss` but not `final`');
  }
  final declared = field.type;
  if (declared is! InterfaceType ||
      declared.classReference.canonicalName?.name != 'Bss') {
    throw DccLowerError(
      '"$name" is `@bss` but declared $declared. Mutable static storage must '
      'be declared `Bss` — it is raw zero-initialized bytes, read and written '
      'through a Pointer<T>. A HeapObject or Weak<T> global would be an ARC '
      'root, which is a frozen memory-model question (CLAUDE.md rule 4) and '
      'is deliberately not expressible here (ADR-0051).',
    );
  }
  final initializer = field.initializer;
  if (initializer is! ConstantExpression) {
    throw DccLowerError(
      '"$name" is `@bss` but its initializer is not a compile-time constant. '
      'Write `const Bss(bytes: N)` — the SIZE must be known at compile time.',
    );
  }
  final constant = initializer.constant;
  if (constant is! InstanceConstant) {
    throw DccLowerError('"$name": `@bss` initializer must be `const Bss(...)`');
  }

  int? bytes;
  int align = 8;
  constant.fieldValues.forEach((ref, value) {
    final fieldName = ref.canonicalName?.name;
    if (value is! IntConstant) return;
    if (fieldName == 'bytes') bytes = value.value;
    if (fieldName == 'align') align = value.value;
  });

  final size = bytes;
  if (size == null || size <= 0) {
    throw DccLowerError(
      '"$name": `@bss` needs a positive `bytes:` size, got $bytes',
    );
  }
  if (align <= 0 || (align & (align - 1)) != 0) {
    throw DccLowerError(
      '"$name": `@bss` alignment must be a positive power of two, got $align. '
      'A hardware structure at the wrong alignment faults rather than running '
      'slowly, so this is rejected rather than rounded.',
    );
  }
  return DCGlobal(
    linkName: name,
    initializer: DCZeroInit(size),
    alignBytes: align,
    isMutable: true,
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
    case DCZeroInit():
      return; // no relocations inside zero-initialized storage
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
/// Evaluates a compile-time double expression, or returns null if it is not
/// one (ADR-0065). The float counterpart of [_tryFoldConstInt], and
/// deliberately narrower: literals and CFE-evaluated constants only, no
/// arithmetic folding — nothing has needed `f64(HALF * 3.0)` yet, and float
/// constant folding has a rounding-order question (fold in the host, or
/// emit the ops?) that deserves deciding against a real case, not in
/// passing. An integer literal in a double context never reaches here as an
/// IntLiteral: the CFE has already converted it (`f64(2)` arrives as
/// DoubleLiteral(2.0)).
double? _tryFoldConstDouble(Expression expr) {
  if (expr is DoubleLiteral) return expr.value;
  if (expr is ConstantExpression) {
    final constant = expr.constant;
    return constant is DoubleConstant ? constant.value : null;
  }
  return null;
}

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

/// A local function that has been HOISTED to a top-level symbol (ADR-0057).
///
/// [node] is the Kernel `FunctionNode` of the function expression or local
/// function declaration; [linkName] is the symbol it will be emitted under;
/// [visibleLocalFunctions] is the set of sibling (and own) hoisted names in
/// scope where it was declared, so a body may call a sibling or recurse.
///
/// This exists only for the NON-CAPTURING case. See
/// docs/escalations/0008-closure-capture-and-indirect-call-elision.md for why
/// the capturing case is not an extension of this and cannot be decided here.
final class _HoistedClosure {
  final FunctionNode node;
  final String linkName;
  final Map<VariableDeclaration, _LocalFunction> visibleLocalFunctions;

  /// The enclosing top-level `Procedure`. Carried only because
  /// `_BareFunctionLowerer` is constructed from one and uses it for nothing
  /// else once [node] is supplied.
  final Procedure enclosingProc;

  /// The enclosing function's `T` -> concrete-type map (ADR-0052), inherited
  /// so a local function declared inside a specialization resolves its own
  /// signature the same way its enclosing body does.
  final Map<String, DartType> typeSubstitution;

  const _HoistedClosure(
    this.node,
    this.linkName,
    this.visibleLocalFunctions,
    this.enclosingProc,
    this.typeSubstitution,
  );
}

/// A local function in scope: what symbol it hoisted to, and its Kernel
/// signature, which a call site needs in order to type-check its arguments
/// and compute `Call.argOwnership` EXACTLY (ADR-0057). The signature is
/// available because the callee is statically known -- that is the entire
/// difference between this and a call through a function VALUE, which has no
/// known callee and therefore no derivable ownership (escalation 0008).
final class _LocalFunction {
  final String linkName;
  final FunctionNode node;
  const _LocalFunction(this.linkName, this.node);
}

/// Module-level state for hoisting local functions (ADR-0057): the queue of
/// bodies still to emit, and every symbol name already claimed.
///
/// Shaped like ADR-0052's specialization queue on purpose -- both discover
/// new top-level functions while lowering an existing one, and both must emit
/// each discovered function exactly once however many times it is referenced.
final class _ClosureHoister {
  final Map<String, _HoistedClosure> pending = {};
  final Set<String> emitted = {};

  /// Every symbol name already spoken for: this module's own top-level
  /// procedures, seeded before any body is lowered, plus every hoisted name
  /// handed out so far.
  final Set<String> claimed = {};

  /// Reserves a unique symbol for a local function named [localName] declared
  /// inside [enclosingLinkName].
  ///
  /// `twiceSum$dbl`, not `dbl`: two enclosing functions may each declare a
  /// local named `f`, and `linkName` is emitted verbatim (spec §9) with no
  /// mangling anywhere downstream, so an unqualified hoist would silently let
  /// one definition win. `$` IS legal in a Dart identifier, so a qualified
  /// name is not collision-proof on its own -- hence [claimed], which
  /// resolves a collision by appending `$2`, `$3`, ... deterministically in
  /// lowering order rather than resting on an assumption about identifiers.
  String reserve(String enclosingLinkName, String? localName) {
    final base = '$enclosingLinkName\$${localName ?? 'anon'}';
    var name = base;
    var n = 2;
    while (claimed.contains(name)) {
      name = '$base\$$n';
      n++;
    }
    claimed.add(name);
    return name;
  }
}

/// Decides whether one local function CAPTURES anything (ADR-0057).
///
/// Deliberately does NOT descend into a nested function's own body: each
/// nested function is hoisted (and therefore scanned) in its own right when
/// the enclosing body is lowered, so descending here would only report the
/// inner function's capture against the OUTER function's name, which is the
/// wrong place to point at.
///
/// Two kinds of reference are tracked separately, because they have opposite
/// answers:
///
///   VALUE position   (`VariableGet`/`VariableSet`) -- a free one is a real
///                    capture. It needs an environment, therefore an
///                    allocator, therefore escalation 0002.
///   CALL position    (`LocalFunctionInvocation`, or a `FunctionInvocation`
///                    whose receiver is a plain `VariableGet`) -- a free one
///                    is NOT a capture if it names another hoisted local
///                    function, because that name resolves to a static
///                    symbol, not to a value in a frame. This is what makes
///                    self-recursion and sibling calls work.
final class _ClosureScan extends RecursiveVisitor {
  final Set<VariableDeclaration> declared = {};
  final Set<VariableDeclaration> valueUses = {};
  final Set<VariableDeclaration> callUses = {};
  bool usesThis = false;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    declared.add(node);
    super.visitVariableDeclaration(node);
  }

  @override
  void visitVariableGet(VariableGet node) {
    valueUses.add(node.variable);
    super.visitVariableGet(node);
  }

  @override
  void visitVariableSet(VariableSet node) {
    valueUses.add(node.variable);
    super.visitVariableSet(node);
  }

  @override
  void visitLocalFunctionInvocation(LocalFunctionInvocation node) {
    callUses.add(node.variable);
    node.arguments.accept(this);
  }

  @override
  void visitFunctionInvocation(FunctionInvocation node) {
    final receiver = node.receiver;
    if (receiver is VariableGet) {
      // Call position, not value position: `f(x)` where `f` is a local bound
      // to a function expression reads as a VariableGet in Kernel, but the
      // value is never materialized -- it is the callee.
      callUses.add(receiver.variable);
    } else {
      receiver.accept(this);
    }
    node.arguments.accept(this);
  }

  @override
  void visitThisExpression(ThisExpression node) {
    usesThis = true;
  }

  // Stop at a nested function boundary (see this class's doc comment). A
  // local function DECLARATION still contributes its own name to `declared`,
  // so a sibling call to it is not reported as free.
  @override
  void visitFunctionExpression(FunctionExpression node) {}

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    declared.add(node.variable);
  }
}

/// A generic function plus the concrete types to specialize it at
/// (ADR-0052).
final class _Specialization {
  final Procedure proc;
  final Map<String, DartType> substitution;
  const _Specialization(this.proc, this.substitution);
}

/// (ADR-0054) A class plus the concrete types it is instantiated at --
/// `Box<u64>`. This is the unit that has a layout, a payload size, a
/// destructor and a set of method bodies; the `Class` alone has none of
/// those, exactly as ADR-0052's generic FUNCTION has no body.
///
/// A NON-generic class is the degenerate case: an empty [typeArgs], whose
/// [mangledName] is the class's own name. Every pre-existing symbol
/// (`Account_net`, `BoxHolder_dtor`) therefore keeps the name it had, and
/// the whole of M2 is unaffected by this being one mechanism rather than a
/// separate path for generics.
final class _ClassInstance {
  final Class cls;
  final List<DartType> typeArgs;
  const _ClassInstance(this.cls, this.typeArgs);

  /// `Box$u64`, or plain `Account` when non-generic. Reuses ADR-0052's
  /// function mangling verbatim rather than inventing a second scheme --
  /// same `$` separator, same reason (`$` cannot appear in a Dart
  /// identifier, and `linkName` goes out verbatim per spec §9).
  String get mangledName =>
      typeArgs.isEmpty ? cls.name : specializationLinkName(cls.name, typeArgs);

  /// `T` -> the concrete type, for lowering this instantiation's fields and
  /// method bodies.
  Map<String, DartType> get substitution {
    if (typeArgs.isEmpty) return const {};
    final params = cls.typeParameters;
    if (params.length != typeArgs.length) {
      throw DccLowerError(
        '"${cls.name}" declares ${params.length} type parameters but was '
        'instantiated with ${typeArgs.length} type arguments',
      );
    }
    final result = <String, DartType>{};
    for (var i = 0; i < params.length; i++) {
      final name = params[i].name;
      if (name == null) {
        throw DccLowerError(
          '"${cls.name}": type parameter $i has no name in the Kernel IR, so '
          'nothing in its body could refer to it — this is a frontend '
          'invariant break, not a source error',
        );
      }
      result[name] = typeArgs[i];
    }
    return result;
  }
}

/// (ADR-0054) Monomorphization's classic failure mode is unbounded code
/// growth, and its unbounded case is real rather than theoretical: `f<T>`
/// calling `f<Box<T>>` builds `Box<Box<Box<...>>>` and queues
/// specializations forever. GAP-0040 recorded that as unguarded because
/// generic classes did not exist to build the infinite type WITH; they do
/// now, so it is guarded here.
///
/// Two bounds, because they catch different shapes:
///
///  * [_maxTypeArgNesting] catches the recursive case directly and early,
///    naming the type that ran away.
///  * [_maxInstantiations] is the backstop for merely-excessive breadth,
///    where no single type is deep but the cross product is large.
///
/// Both are diagnostics, not silent truncation: exceeding either is a
/// compile error naming what was being instantiated. A program that
/// legitimately needs more should raise the bound deliberately, in a commit
/// that says why.
const int _maxTypeArgNesting = 8;
const int _maxInstantiations = 512;

void _checkInstantiationBudget(String baseName, List<DartType> typeArgs, int alreadyEmitted) {
  for (final arg in typeArgs) {
    final depth = _typeArgNesting(arg);
    if (depth > _maxTypeArgNesting) {
      throw DccLowerError(
        'monomorphizing "$baseName" reached a type argument nested $depth '
        'levels deep (limit $_maxTypeArgNesting). This is almost always '
        'recursion through a type parameter — a generic that calls or '
        'constructs itself at `Something<T>` — which has no finite set of '
        'specializations. Monomorphization cannot express it '
        '(docs/decisions/0054-generic-classes.md).',
      );
    }
  }
  if (alreadyEmitted >= _maxInstantiations) {
    throw DccLowerError(
      'monomorphizing "$baseName" would exceed $_maxInstantiations distinct '
      'instantiations in one compilation unit. Identical instantiations are '
      'deduplicated by mangled name, so this is $_maxInstantiations genuinely '
      'DIFFERENT ones — see docs/decisions/0054-generic-classes.md on code '
      'size.',
    );
  }
}

int _typeArgNesting(DartType type) {
  if (type is InterfaceType && type.typeArguments.isNotEmpty) {
    var deepest = 0;
    for (final arg in type.typeArguments) {
      final d = _typeArgNesting(arg);
      if (d > deepest) deepest = d;
    }
    return 1 + deepest;
  }
  return 0;
}

/// (ADR-0054) Applies a type substitution, recursing into type ARGUMENTS.
///
/// ADR-0052's `_resolveTypeParameter` only had to handle a bare `T`, because
/// a generic function's signature could only mention `T` directly -- there
/// was no generic type to nest it inside. `Box<T>` inside a generic function
/// or a generic class's field is exactly that nesting, so substitution has
/// to be structural now rather than a single map lookup.
DartType _substituteType(DartType type, Map<String, DartType> substitution) {
  if (substitution.isEmpty) return type;
  if (type is TypeParameterType) {
    final name = type.parameter.name;
    if (name == null) return type;
    return substitution[name] ?? type;
  }
  if (type is InterfaceType && type.typeArguments.isNotEmpty) {
    final args = [
      for (final arg in type.typeArguments) _substituteType(arg, substitution),
    ];
    var changed = false;
    for (var i = 0; i < args.length; i++) {
      if (!identical(args[i], type.typeArguments[i])) changed = true;
    }
    if (!changed) return type;
    return InterfaceType(type.classNode, type.declaredNullability, args);
  }
  return type;
}

/// The emitted symbol name for a monomorphized generic (ADR-0052).
///
/// `pick$u64`. The `$` cannot appear in a Dart identifier, so a specialization
/// can never collide with a hand-written function name -- which matters
/// because `linkName` is emitted verbatim (spec §9) with no mangling
/// downstream.
String specializationLinkName(String base, List<DartType> typeArgs) {
  final parts = typeArgs.map(_typeArgMangle).join('\$');
  return '$base\$$parts';
}

String _typeArgMangle(DartType type) {
  if (type is ExtensionType) return type.extensionTypeDeclaration.name;
  if (type is InterfaceType) {
    final base = type.classReference.canonicalName?.name ?? 'T';
    // (ADR-0054) Recurse into the type argument's OWN type arguments.
    // Before generic classes existed, an `InterfaceType` type argument
    // could never itself be generic, so dropping them was invisible. It is
    // not invisible now: `pick<Box<u64>>` and `pick<Box<Node>>` would
    // otherwise both mangle to `pick$Box`, and the queue -- which
    // deduplicates by mangled name -- would emit ONE body for two
    // different layouts. Same spelling as `_ClassInstance.mangledName`,
    // and deliberately the same function, so a class instantiation and a
    // function specialization can never disagree about what a type is
    // called.
    if (type.typeArguments.isEmpty) return base;
    return '$base\$${type.typeArguments.map(_typeArgMangle).join('\$')}';
  }
  return type.toString().replaceAll(RegExp(r'[^A-Za-z0-9_]'), '');
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
    // (ADR-0051) `@bss` — mutable zero-initialized storage. Collected here
    // rather than in a separate walk because it shares every rule `@rodata`
    // has: `final` field, `const` initializer, name-keyed symbol.
    if (_hasMarkerAnnotation(field.annotations, '_Bss', preludeUri)) {
      globals.add(_bssGlobal(field));
      continue;
    }
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

/// An extra sentence appended to a type-mismatch diagnostic when the two types
/// differ ONLY in ARC convention (ADR-0060).
///
/// Without it the message reads `DCFuncPtr(u64 Function(@owned HeapRef<void>))`
/// versus `DCFuncPtr(u64 Function(HeapRef<void>))`, which is accurate and
/// completely unhelpful: the reader can see the difference but not why the
/// compiler will not bridge it, and the obvious next move -- writing `@owned`
/// inside the Dart function type -- is not expressible. Says so directly.
String _funcPtrConventionHint(DCType expected, DCType actual) {
  if (expected is! DCFuncPtr || actual is! DCFuncPtr) return '';
  if (expected.params.length != actual.params.length) return '';
  if (expected.returnType != actual.returnType) return '';
  var ownershipOnly = false;
  for (var i = 0; i < expected.params.length; i++) {
    if (expected.params[i].type != actual.params[i].type) return '';
    if (expected.params[i].owned != actual.params[i].owned) ownershipOnly = true;
  }
  if (!ownershipOnly) return '';
  return '. These two function types differ ONLY in ARC convention (`@owned`), '
      'and that is part of the type: coercing either direction is a double '
      'release or a leak (ADR-0060). A Dart function type cannot carry `@owned` '
      '-- annotations live on parameter DECLARATIONS, and a function type has '
      'none -- so a slot declared with an ordinary function type can only hold '
      'a pointer to a BORROWING function. Take the heap argument borrowed, or '
      'call the consuming function directly (docs/known-gaps.md GAP-0057)';
}
