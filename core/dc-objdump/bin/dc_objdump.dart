#!/usr/bin/env dart
// core/dc-objdump/bin/dc_objdump.dart
//
// `dc-objdump --arc <source.dart>` (CLAUDE.md's testing rules: "Anything
// touching ARC codegen also needs an elision test: assert the expected
// number of dc_retain/dc_release calls in the emitted IR... dc-objdump
// --arc prints the counts.") This tool has been a documented obligation
// since M2's first ARC slice (ADR-0015/0016) but was never actually built
// until now -- a real compliance gap against this project's own testing
// rules, closed here rather than left unaddressed indefinitely.
//
// Counts at the DC-IR level (`lowerToDCModule`'s own output), not the
// backend's emitted LLVM text or the final object file: this project's
// Retain/Release/MakeWeak/WeakLoad/DropWeak are all INLINED at the backend
// stage (ADR-0009/0015's "recognized intrinsics lowered inline" -- there
// is no `call @dc_retain` symbol anywhere in the object file to count).
// DC-IR is the one real, meaningful place "how many ARC operations does
// this function have" is a countable, stable question -- and it's
// literally what dcc-lower ITSELF calls "the emitted IR" it produces
// (core/dcc-lower/README.md's own framing: Kernel IR -> dcc-lower ->
// DC-IR). Once elision (docs/known-gaps.md GAP-0017 item 2, M3 scope)
// exists, THIS is where its effect becomes visible: the same source
// program should show smaller Retain/Release counts here after an elision
// pass runs than before one exists.
//
// Usage:
//   cd core/dc-objdump && dart pub get   # once
//   dart bin/dc_objdump.dart --arc path/to/source.dart
//
// Exit codes: 0 success, 64 usage error, 65 input file not found,
// 1 lowering failed (mirrors dcc's own exit-code convention).

import 'dart:io';

import 'package:dc_ir/dc_ir.dart';
import 'package:dc_elide/elide.dart';
import 'package:dcc_lower/lower.dart';

const String _usage = '''
Usage: dc-objdump --arc [--no-elide] <source.dart>

Lowers <source.dart> through dcc-lower and prints, per function, how many
of each ARC-relevant DC-IR instruction it contains: Alloc, Retain,
Release, MakeWeak, WeakLoad, DropWeak.

  --why        Report, per function, WHY pending retains failed to pair --
               and which pass removed the ones that did not:
               blockLimited (reached the end of a block unmatched, and the
               cross-block frontier pass could not place it either),
               opaqueLimited (a non-transparent Call, an IndirectCall or a
               weak op invalidated it -- ADR-0066's transparency summary is
               what shrank this class), releaseLimited (a surviving Release,
               ADR-0063 -- needs escalation 0011), elided/crossBlock/nullOps
               (removed per-block, by the frontier pass, or as a null no-op,
               ADR-0066). Counts are attempts, not distinct pairs.
               "Elision removes 5% here" does not say what to fix; this does.

  --no-elide   Skip ADR-0025's redundant-pair elision, so the counts are what
               lowering PRODUCED rather than what survived. Diffing the two
               runs is how you measure what the pass actually removes on a
               given program -- which nothing could do before, because
               elision ran unconditionally inside lowering and this tool only
               ever saw the post-elision numbers. "The pass fires" is proved
               by its unit tests; "the pass removes N of M pairs HERE" is a
               different question and decides whether an ARC benchmark is
               measuring ARC or measuring a missing optimisation.
''';

Future<void> main(List<String> argv) async {
  final elisionStats = <String, ElisionStats>{};
  final noElide = argv.contains('--no-elide');
  final why = argv.contains('--why');
  final positional =
      argv.where((a) => a != '--no-elide' && a != '--why').toList();
  if (positional.length != 2 || positional[0] != '--arc') {
    stderr.writeln(_usage);
    exit(64);
  }

  final inputPath = positional[1];
  final inputFile = File(inputPath);
  if (!inputFile.existsSync()) {
    stderr.writeln('dc-objdump: input file not found: $inputPath');
    exit(65);
  }

  final preludeUri = Platform.script.resolve('../../runtime/dc-core-bare/prelude.dart');

  final DCModule module;
  try {
    module = await lowerToDCModule(
      inputPath,
      preludeUri: preludeUri,
      elide: !noElide,
      elisionStats: why ? elisionStats : null,
    );
  } catch (e) {
    stderr.writeln('dc-objdump: $e');
    exit(1);
  }

  final totals = _ArcCounts();
  stdout.writeln('${module.name}:');
  for (final function in module.functions) {
    final counts = _ArcCounts();
    for (final block in function.blocks) {
      for (final instruction in block.body) {
        counts.tally(instruction);
      }
    }
    totals.add(counts);
    stdout.writeln('  ${function.linkName}: ${counts.format()}');
  }
  stdout.writeln('  TOTAL: ${totals.format()}');

  if (why) {
    stdout.writeln();
    stdout.writeln('  WHY pending retains failed to pair:');
    var elided = 0,
        crossBlock = 0,
        nullOps = 0,
        blockLimited = 0,
        opaqueLimited = 0,
        releaseLimited = 0;
    for (final entry in elisionStats.entries) {
      final st = entry.value;
      if (st.elided == 0 &&
          st.crossBlockElided == 0 &&
          st.nullElided == 0 &&
          st.blockLimited == 0 &&
          st.opaqueLimited == 0 &&
          st.releaseLimited == 0) {
        continue;
      }
      stdout.writeln('    ${entry.key}: $st');
      elided += st.elided;
      crossBlock += st.crossBlockElided;
      nullOps += st.nullElided;
      blockLimited += st.blockLimited;
      opaqueLimited += st.opaqueLimited;
      releaseLimited += st.releaseLimited;
    }
    stdout.writeln(
      '    WHY-TOTAL: elided=$elided crossBlock=$crossBlock nullOps=$nullOps '
      'blockLimited=$blockLimited '
      'opaqueLimited=$opaqueLimited releaseLimited=$releaseLimited',
    );
  }
}

/// Per-function (or aggregate) counts of every ARC-relevant DC-IR
/// instruction. Deliberately counts `Alloc` too, not just the four ARC ops
/// proper -- "how many allocations vs. how many retains" is exactly the
/// ratio spec §3.2's elision passes exist to shrink (fewer retains per
/// alloc as escape analysis/borrow inference/move semantics land).
class _ArcCounts {
  int alloc = 0;
  int retain = 0;
  int release = 0;
  int makeWeak = 0;
  int weakLoad = 0;
  int dropWeak = 0;

  void tally(DCInstruction instruction) {
    switch (instruction) {
      case Alloc():
        alloc++;
      case Retain():
        retain++;
      case Release():
        release++;
      case MakeWeak():
        makeWeak++;
      case WeakLoad():
        weakLoad++;
      case DropWeak():
        dropWeak++;
      default:
        break;
    }
  }

  void add(_ArcCounts other) {
    alloc += other.alloc;
    retain += other.retain;
    release += other.release;
    makeWeak += other.makeWeak;
    weakLoad += other.weakLoad;
    dropWeak += other.dropWeak;
  }

  String format() =>
      'alloc=$alloc retain=$retain release=$release makeweak=$makeWeak weakload=$weakLoad dropweak=$dropWeak';
}
