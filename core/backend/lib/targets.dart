// core/backend/lib/targets.dart
//
// The target registry: which machine, OS and object format `dcc` is
// compiling for. See docs/decisions/0033-target-registry.md.
//
// WHY THIS IS SEPARATE FROM `BuildMode`
//
// `--mode` (DCDART_SPEC.md §2: `bare` vs `hosted`) and `--target` answer two
// different questions, and conflating them was the bug this file fixes:
//
//   --mode   = which LANGUAGE SUBSET and runtime the source may use.
//              `bare` means no allocator, no ORC, no threads, no throw.
//              `hosted` means the full runtime — which does not exist yet.
//   --target = which MACHINE, OS and OBJECT FORMAT to emit for.
//              x86-64 vs aarch64, ELF vs Mach-O vs COFF.
//
// These are orthogonal. A `@bare` object file is a plain C-ABI object file
// (m0-target.md §1: no `dso_local`, no custom calling convention), so it
// links into an ordinary hosted C program with real libc on a real OS —
// `examples/demo-collatz/main.c` has been doing exactly that all along. The
// ONLY thing that stopped `dcc` from producing a native macOS or Windows
// binary was that `dcc/lib/pipeline.dart` hardcoded the freestanding
// x86-64 triple. Nothing in the emitted IR was actually ELF-specific.
//
// So: `--mode bare` + `--target arm64-apple-macosx` is a legitimate and
// now-verified combination. It does NOT mean "hosted mode is implemented" —
// spec §2's `@hosted` still needs a runtime nobody has built.

/// The object-file container a target emits. Chosen by the triple's OS
/// field; `clang` does the actual writing, this is only used for
/// diagnostics and for the freestanding checker's symbol-prefix rules.
enum ObjectFormat {
  elf,
  machO,
  coff;

  /// Mach-O prefixes C symbols with an underscore at the object level, so
  /// `add` is emitted as `_add`. `scripts/verify-freestanding.sh` already
  /// normalizes this away (`sed 's/^_//'`) — recorded here so nothing else
  /// has to rediscover it.
  bool get prefixesSymbolsWithUnderscore => this == ObjectFormat.machO;
}

/// Instruction set. Only the two this project actually emits and tests for;
/// adding a third means adding a real conformance target for it, not just
/// an enum case (`CLAUDE.md` testing rules).
enum TargetArch {
  x86_64,
  aarch64;

  /// `Port.outb`/`Port.inb` (ADR-0029) emit x86 `outb`/`inb` inline asm.
  /// They are x86-only AND ring-0-only. On any other arch the correct
  /// behaviour is a clear compile-time error naming the instruction, not an
  /// unreadable failure from `clang` about an unknown asm mnemonic.
  bool get supportsPortIo => this == TargetArch.x86_64;
}

/// The OS the object file is destined for. `none` is the freestanding
/// bare-metal case (`x86_64-unknown-none-elf`, M0's original target) —
/// no OS, no libc, no dynamic loader.
enum TargetOs { none, linux, macos, windows }

/// A compilation target: an LLVM triple plus the facts about it that the
/// compiler needs to make decisions.
///
/// Constructed via [DCTarget.parse] (from a `--target` value) or
/// [DCTarget.host] (from the machine `dcc` is running on). Both go through
/// the same validation, so any `DCTarget` in hand is one this backend has
/// actually been taught to emit for — an unknown triple is rejected at the
/// CLI rather than handed to `clang` to fail on later in a worse way.
class DCTarget {
  /// The LLVM triple, passed to both `emitModule`'s `target triple` line and
  /// `clang --target=`. These two MUST stay in sync — `compile.dart`'s own
  /// doc comment warns that a conflicting `--target=` silently overrides the
  /// `.ll` file's own triple rather than erroring.
  final String triple;

  final TargetArch arch;
  final TargetOs os;
  final ObjectFormat objectFormat;

  /// The short `--target` alias this target is reachable by, if any.
  final String? alias;

  const DCTarget({
    required this.triple,
    required this.arch,
    required this.os,
    required this.objectFormat,
    this.alias,
  });

  /// Whether emitted code must NOT use the x86-64 red zone.
  ///
  /// The red zone is 128 bytes below RSP that a leaf function may use without
  /// adjusting the stack, on the promise that nothing else will touch it.
  /// Interrupts break that promise: the CPU pushes its interrupt frame at RSP
  /// and lands directly on top of those locals. In userland that is fine —
  /// the kernel switches stacks for you. In kernel or bare-metal code it is
  /// silent memory corruption the moment interrupts are enabled: no fault, no
  /// diagnostic, just wrong values later.
  ///
  /// So this is exactly the freestanding property, which is why it lives on
  /// the target rather than being a flag someone has to remember to pass
  /// (ADR-0039). A future freestanding target cannot get this wrong by
  /// omission.
  ///
  /// Applied to aarch64 freestanding targets too even though AAPCS64 has no
  /// red zone to disable: `clang` accepts `-mno-red-zone` there without
  /// complaint, and asserting the property uniformly is safer than encoding
  /// an arch-by-arch exception list that a new arch would silently fall out
  /// of.
  bool get forbidsRedZone => isFreestanding;

  /// True for bare-metal targets with no OS underneath. A freestanding
  /// object cannot be linked into an ordinary executable by the host
  /// toolchain without a hand-written entry stub — which is exactly what
  /// `tests/conformance/*/run.sh` step 3 supplies.
  bool get isFreestanding => os == TargetOs.none;

  /// M0's original target (`core/backend/m0-target.md` §1), and still the
  /// default when `--target` is not given, so every existing conformance
  /// harness keeps compiling byte-for-byte the same object it did before
  /// the registry existed.
  static const bareX86_64 = DCTarget(
    triple: 'x86_64-unknown-none-elf',
    arch: TargetArch.x86_64,
    os: TargetOs.none,
    objectFormat: ObjectFormat.elf,
    alias: 'bare-x86_64',
  );

  static const bareAarch64 = DCTarget(
    triple: 'aarch64-unknown-none-elf',
    arch: TargetArch.aarch64,
    os: TargetOs.none,
    objectFormat: ObjectFormat.elf,
    alias: 'bare-aarch64',
  );

  static const linuxX86_64 = DCTarget(
    triple: 'x86_64-unknown-linux-gnu',
    arch: TargetArch.x86_64,
    os: TargetOs.linux,
    objectFormat: ObjectFormat.elf,
    alias: 'linux-x86_64',
  );

  static const linuxAarch64 = DCTarget(
    triple: 'aarch64-unknown-linux-gnu',
    arch: TargetArch.aarch64,
    os: TargetOs.linux,
    objectFormat: ObjectFormat.elf,
    alias: 'linux-aarch64',
  );

  static const macosX86_64 = DCTarget(
    triple: 'x86_64-apple-macosx11.0.0',
    arch: TargetArch.x86_64,
    os: TargetOs.macos,
    objectFormat: ObjectFormat.machO,
    alias: 'macos-x86_64',
  );

  static const macosAarch64 = DCTarget(
    triple: 'arm64-apple-macosx11.0.0',
    arch: TargetArch.aarch64,
    os: TargetOs.macos,
    objectFormat: ObjectFormat.machO,
    alias: 'macos-arm64',
  );

  static const windowsX86_64 = DCTarget(
    triple: 'x86_64-pc-windows-msvc',
    arch: TargetArch.x86_64,
    os: TargetOs.windows,
    objectFormat: ObjectFormat.coff,
    alias: 'windows-x86_64',
  );

  static const windowsAarch64 = DCTarget(
    triple: 'aarch64-pc-windows-msvc',
    arch: TargetArch.aarch64,
    os: TargetOs.windows,
    objectFormat: ObjectFormat.coff,
    alias: 'windows-arm64',
  );

  /// Every target reachable by a short alias, in the order `--help` lists
  /// them. `bare-x86_64` first because it is the default.
  static const all = <DCTarget>[
    bareX86_64,
    bareAarch64,
    linuxX86_64,
    linuxAarch64,
    macosX86_64,
    macosAarch64,
    windowsX86_64,
    windowsAarch64,
  ];

  /// The target used when `--target` is omitted.
  static const DCTarget defaultTarget = bareX86_64;

  /// Resolves the machine `dcc` itself is running on, so `--target host`
  /// produces an object that links into an ordinary native program with the
  /// system C compiler and no cross-toolchain.
  ///
  /// [osName] and [archName] take `Platform.operatingSystem` and the
  /// architecture portion of `Platform.version` respectively; they are
  /// parameters rather than direct `dart:io` reads so this stays a pure
  /// function that unit tests can drive without faking a platform.
  static DCTarget host({required String osName, required String archName}) {
    final isArm = archName.contains('arm64') || archName.contains('aarch64');
    switch (osName) {
      case 'macos':
        return isArm ? macosAarch64 : macosX86_64;
      case 'linux':
        return isArm ? linuxAarch64 : linuxX86_64;
      case 'windows':
        return isArm ? windowsAarch64 : windowsX86_64;
      default:
        throw UnsupportedTargetError(
          'no native target is defined for host OS "$osName". DCDart emits '
          'for macOS, Linux and Windows on x86-64/arm64; pass an explicit '
          '--target for anything else.\n\n${describeAll()}',
        );
    }
  }

  /// Parses a `--target` value: either a short alias (`macos-arm64`), the
  /// literal string `host`, or a full LLVM triple that matches one of the
  /// registered targets.
  ///
  /// Deliberately does NOT accept an arbitrary triple and guess its
  /// properties. A triple this backend has never emitted for is an honest
  /// "not supported yet" — guessing would produce an object file nobody has
  /// tested, which `CLAUDE.md`'s testing rules exist to prevent.
  static DCTarget parse(
    String value, {
    required String hostOsName,
    required String hostArchName,
  }) {
    if (value == 'host') {
      return host(osName: hostOsName, archName: hostArchName);
    }
    for (final target in all) {
      if (target.alias == value || target.triple == value) return target;
    }
    throw UnsupportedTargetError(
      'unknown --target "$value".\n\n${describeAll()}',
    );
  }

  /// The `--help`/error-message listing of everything `--target` accepts.
  static String describeAll() {
    final buffer = StringBuffer('Supported targets:\n');
    buffer.writeln('  host'.padRight(20) + 'the machine dcc is running on');
    for (final target in all) {
      buffer.writeln('  ${target.alias!}'.padRight(20) + target.triple);
    }
    return buffer.toString();
  }

  @override
  String toString() => alias ?? triple;
}

/// Thrown for a `--target` value this backend cannot emit for. Separate
/// from the CLI's own usage error so `pipeline.dart` can also throw it when
/// a target and a language feature are incompatible (see
/// [checkFeatureSupport]).
class UnsupportedTargetError implements Exception {
  final String message;
  const UnsupportedTargetError(this.message);

  @override
  String toString() => message;
}

/// Rejects source that uses a feature the chosen target cannot express,
/// BEFORE handing anything to `clang`.
///
/// Today that is exactly one feature: `Port.outb`/`Port.inb` (ADR-0029)
/// emit x86 `outb`/`inb` inline asm. Compiling `examples/m2-port` for
/// arm64 without this check fails deep inside `clang` with an unreadable
/// message about an invalid asm operand; with it, the user is told which
/// construct is unsupported on which target, which is the difference
/// between a diagnostic and a crash.
///
/// [usesPortIo] is computed by the caller from the lowered module (see
/// `pipeline.dart`), keeping this package free of a DC-IR walk that
/// `llvm_emit.dart` already knows how to do.
void checkFeatureSupport(DCTarget target, {required bool usesPortIo}) {
  if (usesPortIo && !target.arch.supportsPortIo) {
    throw UnsupportedTargetError(
      'this program uses Port.outb/Port.inb, which emit x86 `outb`/`inb` '
      'instructions (docs/decisions/0029-port-io.md), but --target '
      '${target} is ${target.arch.name}. Port I/O is x86-only (and '
      'ring-0-only). Build this program for an x86-64 target, or drop the '
      'port I/O.',
    );
  }
}
