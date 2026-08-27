// core/dcc/lib/pipeline.dart
//
// The real compilation pipeline, per DCDART_SPEC.md §1 `[LOAD-BEARING]`:
//
//   .dart -> [dart compile kernel] -> Kernel IR (.dill) -> [dcc-lower] ->
//   DC-IR -> [backend] -> LLVM IR -> [clang -c] -> object file
//
// See core/docs/decisions/0008-m0-frontend-strategy.md for why the first
// arrow is "the installed SDK's `dart compile kernel`" rather than "the
// vendored pkg/front_end in-process" — that's a deliberate M0 scoping
// choice, not a shortcut nobody noticed.
//
// M0 scope only: recognizes exactly what core/dcc-lower/lib/lower.dart
// recognizes (one `@bare` top-level function, u64 params/return, `a + b`
// body) and nothing past it — see that file's header for the exact cut and
// core/docs/known-gaps.md for what's tracked as still open.

import 'dart:io';

import 'package:backend/c_header.dart';
import 'package:backend/compile.dart';
import 'package:backend/llvm_emit.dart';
import 'package:backend/targets.dart';
import 'package:dc_ir/dc_ir.dart';
import 'package:dcc_lower/lower.dart';

import 'cli_args.dart';

/// Entry point the CLI calls once arguments are parsed AND the input file
/// has been confirmed to exist (see bin/dcc.dart). Writes a real object
/// file to `options.outputPath` on success; throws (and writes nothing) on
/// any failure — see bin/dcc.dart for how each exception type maps to an
/// exit code.
Future<void> runBuild(BuildOptions options) async {
  final preludeUri = _resolvePreludeUri(options.preludePath);

  final module = await lowerToDCModule(
    options.inputPath,
    preludeUri: preludeUri,
  );

  // `--mode` is still bare-only: DCDART_SPEC.md §2's `@hosted` needs an
  // allocator/ORC/threads runtime this project hasn't built, so there is
  // nothing honest to emit for it. NOTE this is unrelated to which OS we
  // target — see backend/lib/targets.dart's header. `--mode bare` with
  // `--target macos-arm64` is a supported, verified combination; it means
  // "the bare language subset, emitted as a native macOS object", not
  // "hosted mode".
  if (options.mode != BuildMode.bare) {
    throw UnimplementedError(
      '--mode hosted has no backend target yet (only --mode bare, per '
      'core/backend/m0-target.md, is implemented) — see '
      'core/docs/known-gaps.md',
    );
  }

  final target = options.target;

  // Reject target/feature mismatches HERE, while we can still name the
  // construct and the target in one sentence. Handing x86 `outb` asm to
  // clang for an aarch64 target fails, but with a message about an invalid
  // asm operand that says nothing about Port.outb (ADR-0033).
  checkFeatureSupport(target, usesPortIo: _usesPortIo(module));

  final llText = emitModule(
    module,
    targetTriple: target.triple,
    noRedZone: target.forbidsRedZone,
    // The heap default is target-dependent: hosted `.bss` is lazily backed by
    // the OS, freestanding `.bss` is physical frames a kernel must find at
    // boot (ADR-0058). Derived from the target rather than passed by hand,
    // the same way `noRedZone` is.
    freestanding: target.isFreestanding,
    heapRegionBytes: options.heapRegionBytes,
  );

  final tempDir = Directory.systemTemp.createTempSync('dcc_backend_');
  try {
    final llFile = File('${tempDir.path}/out.ll')..writeAsStringSync(llText);
    await compileToObject(
      llFile.path,
      options.outputPath,
      targetTriple: target.triple,
      noRedZone: target.forbidsRedZone,
    );
  } finally {
    tempDir.deleteSync(recursive: true);
  }

  // (ADR-0038) The extern manifest: the set of undefined symbols this object
  // file is allowed to carry, written beside it as `<output>.externs` and
  // read by `scripts/verify-freestanding.sh` (CLAUDE.md rule 1,
  // docs/escalations/0003-extern-c-calls-vs-freestanding.md, RATIFIED by the
  // project owner on 2026-08-20 — option 2).
  //
  // Written unconditionally after a successful build, INCLUDING deleting a
  // stale one when this build declares no externs. That deletion is not
  // tidiness: a leftover manifest from a previous build of a different
  // source would silently permit symbols the current object never declared,
  // which is precisely the hole the manifest is supposed to close.
  _writeExternManifest(options.outputPath, module);

  // The header is written only after the object file succeeded, so a failed
  // build never leaves a stale-but-plausible .h next to no .o (ADR-0034).
  final headerPath = options.headerPath;
  if (headerPath != null) {
    File(headerPath).writeAsStringSync(
      emitCHeader(module, headerName: _headerGuardNameFor(headerPath)),
    );
  }
}

/// The manifest path for an object file: the object's own path with
/// `.externs` appended (`build/kernel.o` -> `build/kernel.o.externs`).
/// Appended, not substituted, so the manifest can never collide with another
/// object's name and so the pairing is obvious in a directory listing.
String externManifestPathFor(String objectPath) => '$objectPath.externs';

/// Writes (or removes) the extern manifest beside [objectPath]. See the call
/// site for why removal matters.
void _writeExternManifest(String objectPath, DCModule module) {
  final manifest = File(externManifestPathFor(objectPath));
  if (module.externFunctions.isEmpty) {
    if (manifest.existsSync()) manifest.deleteSync();
    return;
  }
  final buffer = StringBuffer();
  buffer.writeln('# Extern manifest for $objectPath');
  buffer.writeln('# Generated by dcc from ${module.name} — do not edit.');
  buffer.writeln('#');
  buffer.writeln('# Every name below is a C-ABI symbol this object calls but');
  buffer.writeln('# does not define, declared `@extern external` in the source.');
  buffer.writeln('# scripts/verify-freestanding.sh permits exactly these as');
  buffer.writeln('# undefined symbols. Anything else is still a hard failure.');
  for (final extern in module.externFunctions) {
    buffer.writeln(extern.linkName);
  }
  manifest.writeAsStringSync(buffer.toString());
}

/// Whether any function in [module] performs port I/O (ADR-0029), which is
/// x86-only. Walks the module rather than threading a flag out of
/// `dcc-lower`, so nothing upstream has to know this check exists.
bool _usesPortIo(DCModule module) => module.functions.any(
      (f) => f.blocks.any(
        (b) => b.body.any((i) => i is PortOut || i is PortIn),
      ),
    );

/// Turns an output path like `build/account.h` into `ACCOUNT_H`, for the
/// header's include guard. Non-alphanumeric characters become underscores.
String _headerGuardNameFor(String path) {
  final base = path.split(Platform.pathSeparator).last.split('/').last;
  return base.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_').toUpperCase();
}

/// M0 simplification, not a real library resolver: DCDart's real design
/// (DCDART_SPEC.md §2/§8) wants `dc:core.bare` resolved as a proper scheme,
/// the way `dart:core` is — that needs the actual front_end fork
/// (ADR-0008's "deferred, not abandoned" alternative), not built yet. Until
/// then, dcc locates its own prelude relative to where `dcc.dart` itself
/// lives on disk. This means `dcc` currently only works run from inside
/// this checkout at this exact relative layout — true and worth knowing,
/// not hidden behind a name that suggests it's more general than it is.
/// Which file `dcc` treats as THE prelude.
///
/// [override] is `--prelude`'s value, or null for the historical behaviour:
/// the prelude sitting beside this `dcc` in the same checkout.
///
/// The override is made ABSOLUTE and lexically normalised, because that is the
/// form the comparison in `dcc-lower` uses — an annotation counts as `@bare`
/// only if its library's `importUri` equals this Uri exactly, with `..`
/// folded and symlinks resolved on NEITHER side. Passing a relative path and
/// having it silently not match would reproduce the very failure this flag
/// exists to remove.
Uri _resolvePreludeUri(String? override) {
  if (override == null) {
    return Platform.script.resolve('../../runtime/dc-core-bare/prelude.dart');
  }
  return Uri.file(File(override).absolute.path).normalizePath();
}
