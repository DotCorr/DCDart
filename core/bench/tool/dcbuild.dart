#!/usr/bin/env dart
// core/bench/tool/dcbuild.dart
//
// Builds a DCDart source file to a native object file with the ARC REFCOUNT
// MODE as an explicit parameter. This exists for exactly one reason, and it
// is worth stating before anything else:
//
//   docs/escalations/0007-arc-refcount-atomicity.md §5 condition 2 and
//   docs/decisions/0053-string-slices.md's M3 section both require that M3's
//   number be measured in BOTH refcount modes. `dcc build` has no such flag
//   and `backend/lib/llvm_emit.dart` is off-limits to this unit (another
//   session owns it). So the mode is applied HERE, as a rewrite of the
//   emitted LLVM IR text, between `emitModule` and `clang -c`.
//
// That makes this a benchmark tool, not a compiler feature. Nothing else in
// the tree should use it. `--refcount=nonatomic` is required to be
// bit-identical to `dcc build`'s output, and run-bench.sh asserts that on
// every run (see `--selftest-identical`); if it ever diverges, every number
// this harness prints is measuring a compiler nobody ships and the harness
// says so and stops.
//
// Usage:
//   dart --packages=<core>/dcc/.dart_tool/package_config.json \
//        <core>/bench/tool/dcbuild.dart \
//        --refcount=nonatomic|atomic \
//        [--target host] [--emit-ll out.ll] [--print-flags] \
//        -o out.o src.dart
//
// Exit codes:
//   0  success
//   64 usage error
//   1  build failed, or the atomic rewrite did not match the IR it expected

import 'dart:io';

import 'package:backend/llvm_emit.dart';
import 'package:backend/targets.dart';
import 'package:dc_ir/dc_ir.dart';
import 'package:dcc_lower/lower.dart';

/// The clang flags DCDart itself compiles its emitted IR with. These are a
/// TRANSCRIPTION of `core/backend/lib/compile.dart`'s argument list, because
/// that function builds its arguments internally and does not expose them —
/// and a benchmark that cannot state the flags it used is not a measurement.
///
/// The transcription is verified rather than trusted: run-bench.sh's
/// `--selftest-identical` builds the same source through `dcc build` and
/// through this file and requires the two object files to be byte-identical.
/// A drift in compile.dart therefore fails the harness loudly instead of
/// silently biasing the comparison.
///
/// `-O2` matters most: ADR-0042 raised dcc from no `-O` at all to `-O2`, and
/// a C baseline compiled at a different level makes the whole gate
/// meaningless. run-bench.sh applies this exact list to the C side too.
List<String> dcdartClangFlags(DCTarget target) => <String>[
      '--target=${target.triple}',
      '-O2',
      if (target.forbidsRedZone) '-mno-red-zone',
      '-ffreestanding',
      '-fno-builtin',
      '-fno-stack-protector',
      '-fno-exceptions',
      '-fno-unwind-tables',
      '-fno-asynchronous-unwind-tables',
    ];

enum RefcountMode { nonatomic, atomic }

Future<int> main(List<String> argv) async {
  String? input;
  String? output;
  String? emitLl;
  String targetName = 'host';
  RefcountMode? mode;
  var printFlagsOnly = false;

  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--print-flags') {
      printFlagsOnly = true;
    } else if (a.startsWith('--refcount=')) {
      final v = a.substring('--refcount='.length);
      switch (v) {
        case 'nonatomic':
          mode = RefcountMode.nonatomic;
        case 'atomic':
          mode = RefcountMode.atomic;
        default:
          stderr.writeln('dcbuild: --refcount must be nonatomic|atomic, '
              'got "$v"');
          return 64;
      }
    } else if (a == '--target') {
      targetName = argv[++i];
    } else if (a == '--emit-ll') {
      emitLl = argv[++i];
    } else if (a == '-o') {
      output = argv[++i];
    } else if (a.startsWith('-')) {
      stderr.writeln('dcbuild: unknown option "$a"');
      return 64;
    } else {
      input = a;
    }
  }

  final DCTarget target;
  try {
    target = DCTarget.parse(
      targetName,
      hostOsName: Platform.operatingSystem,
      hostArchName: Platform.version,
    );
  } on UnsupportedTargetError catch (e) {
    stderr.writeln('dcbuild: ${e.message}');
    return 64;
  }

  if (printFlagsOnly) {
    stdout.writeln(dcdartClangFlags(target).join(' '));
    return 0;
  }

  if (input == null || output == null || mode == null) {
    stderr.writeln('dcbuild: need --refcount=<mode>, -o <out.o> and <src.dart>');
    return 64;
  }
  if (!File(input).existsSync()) {
    stderr.writeln('dcbuild: input not found: $input');
    return 64;
  }

  // Same relative-path prelude resolution dcc/lib/pipeline.dart uses
  // (`_resolvePreludeUri`). bench/tool/ is the same depth below core/ as
  // dcc/bin/, so the '../../' is identical and not a coincidence to fix.
  final preludeUri =
      Platform.script.resolve('../../runtime/dc-core-bare/prelude.dart');

  final DCModule module;
  try {
    module = await lowerToDCModule(input, preludeUri: preludeUri);
  } catch (e) {
    stderr.writeln('dcbuild: lowering failed: $e');
    return 1;
  }

  var ll = emitModule(
    module,
    targetTriple: target.triple,
    noRedZone: target.forbidsRedZone,
  );

  final arcSites = _countArcUpdateSites(module);
  var rewritten = 0;
  if (mode == RefcountMode.atomic) {
    final result = _makeRefcountUpdatesAtomic(ll);
    ll = result.text;
    rewritten = result.sites;
    if (rewritten != arcSites.contiguous) {
      stderr.writeln(
        'dcbuild: ATOMIC REWRITE MISMATCH — expected ${arcSites.contiguous} '
        'refcount update site(s) from the DC-IR (retain=${arcSites.retain}, '
        'release=${arcSites.release}, makeWeak=${arcSites.makeWeak}, '
        'dropWeak=${arcSites.dropWeak}) but rewrote $rewritten in the emitted '
        'LLVM IR.\n'
        'This means backend/lib/llvm_emit.dart no longer emits refcount '
        'updates in the load/add-1/store shape this rewriter matches. The '
        'rewriter must be updated before ANY atomic-mode number is believed. '
        'Refusing to produce a misleading object file.',
      );
      return 1;
    }
  }

  if (emitLl != null) File(emitLl).writeAsStringSync(ll);

  final tmp = Directory.systemTemp.createTempSync('dcbench_');
  try {
    final llPath = '${tmp.path}/out.ll';
    File(llPath).writeAsStringSync(ll);
    final args = <String>[
      ...dcdartClangFlags(target),
      '-c',
      llPath,
      '-o',
      output,
    ];
    final r = await Process.run('clang', args);
    if (r.exitCode != 0) {
      stderr.writeln('dcbuild: clang failed (exit ${r.exitCode})');
      stderr.writeln(r.stdout);
      stderr.writeln(r.stderr);
      return 1;
    }
  } finally {
    tmp.deleteSync(recursive: true);
  }

  // Machine-readable facts about this build, consumed by run-bench.sh and
  // printed in the results header. `ARC_SITES` is the honest denominator for
  // "how much ARC is in this benchmark at all" — a benchmark with 0 is a
  // benchmark where the two refcount modes MUST produce identical binaries,
  // which is itself one of the harness's self-tests.
  stdout.writeln('DCBUILD_MODE=${mode.name}');
  stdout.writeln('DCBUILD_TARGET=${target.triple}');
  stdout.writeln('DCBUILD_ARC_SITES=${arcSites.contiguous}');
  stdout.writeln('DCBUILD_ARC_RETAIN=${arcSites.retain}');
  stdout.writeln('DCBUILD_ARC_RELEASE=${arcSites.release}');
  stdout.writeln('DCBUILD_ARC_WEAKLOAD=${arcSites.weakLoad}');
  stdout.writeln('DCBUILD_ATOMIC_REWRITES=$rewritten');
  stdout.writeln('DCBUILD_FLAGS=${dcdartClangFlags(target).join(' ')}');
  return 0;
}

class _ArcSites {
  final int retain;
  final int release;
  final int makeWeak;
  final int dropWeak;

  /// `WeakLoad` also increments `strong`, but llvm_emit emits that increment
  /// on the far side of a branch (load, icmp, br, then add/store in the
  /// `weakAlive` block), so it is NOT the contiguous triple this rewriter
  /// matches and it stays non-atomic even in atomic mode. Counted and
  /// reported separately rather than quietly folded in — see README.md
  /// "What atomic mode is and is not".
  final int weakLoad;

  const _ArcSites(
      this.retain, this.release, this.makeWeak, this.dropWeak, this.weakLoad);

  int get contiguous => retain + release + makeWeak + dropWeak;
}

_ArcSites _countArcUpdateSites(DCModule module) {
  var retain = 0, release = 0, makeWeak = 0, dropWeak = 0, weakLoad = 0;
  for (final f in module.functions) {
    for (final b in f.blocks) {
      for (final i in b.body) {
        if (i is Retain) retain++;
        if (i is Release) release++;
        if (i is MakeWeak) makeWeak++;
        if (i is DropWeak) dropWeak++;
        if (i is WeakLoad) weakLoad++;
      }
    }
  }
  return _ArcSites(retain, release, makeWeak, dropWeak, weakLoad);
}

class _RewriteResult {
  final String text;
  final int sites;
  const _RewriteResult(this.text, this.sites);
}

// The three-line sequence llvm_emit.dart emits for every refcount update:
//
//   %strongN   = load i32, ptr %hdrM
//   %newstrongN = add i32 %strongN, 1        (or `sub`, for Release/DropWeak)
//   store i32 %newstrongN, ptr %hdrM
//
// becomes
//
//   %strongN   = atomicrmw add ptr %hdrM, i32 1 seq_cst   ; returns the OLD value
//   %newstrongN = add i32 %strongN, 1
//
// The second line is kept because downstream code uses `%newstrongN` (Release
// compares it against zero to decide whether the object dies). `atomicrmw`
// returns the value BEFORE the operation, so `%strongN` keeps exactly the
// meaning it had, and `%newstrongN` is recomputed from it. Nothing else in
// the block changes.
final RegExp _loadRe = RegExp(r'^(\s*)%([A-Za-z0-9_.]+) = load i32, ptr %([A-Za-z0-9_.]+)$');

_RewriteResult _makeRefcountUpdatesAtomic(String ll) {
  final lines = ll.split('\n');
  final out = <String>[];
  var sites = 0;

  for (var i = 0; i < lines.length; i++) {
    final m = _loadRe.firstMatch(lines[i]);
    if (m == null || i + 2 >= lines.length) {
      out.add(lines[i]);
      continue;
    }
    final indent = m.group(1)!;
    final oldVal = m.group(2)!;
    final ptr = m.group(3)!;

    final rmw = RegExp(
      '^\\s*%([A-Za-z0-9_.]+) = (add|sub) i32 %${RegExp.escape(oldVal)}, 1\$',
    ).firstMatch(lines[i + 1]);
    if (rmw == null) {
      out.add(lines[i]);
      continue;
    }
    final newVal = rmw.group(1)!;
    final op = rmw.group(2)!;

    final storeRe = RegExp(
      '^\\s*store i32 %${RegExp.escape(newVal)}, ptr %${RegExp.escape(ptr)}\$',
    );
    if (!storeRe.hasMatch(lines[i + 2])) {
      out.add(lines[i]);
      continue;
    }

    out.add('$indent%$oldVal = atomicrmw $op ptr %$ptr, i32 1 seq_cst');
    out.add('$indent%$newVal = $op i32 %$oldVal, 1');
    sites++;
    i += 2;
  }

  final header = '; refcount mode: ATOMIC — $sites refcount update site(s) '
      'rewritten to `atomicrmw ... seq_cst` by core/bench/tool/dcbuild.dart.\n'
      '; This is a BENCHMARK-ONLY rewrite. It prices the atomic instruction; '
      'it does NOT make ARC concurrency-correct (escalation 0007 §2a).\n';
  return _RewriteResult(header + out.join('\n'), sites);
}
