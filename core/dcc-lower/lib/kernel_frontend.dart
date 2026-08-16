// core/dcc-lower/lib/kernel_frontend.dart
//
// M0's frontend stage (docs/decisions/0008-m0-frontend-strategy.md): shells
// out to the installed Dart SDK's stable `dart compile kernel` CLI to get
// real Kernel IR for a DCDart source file, rather than embedding the
// vendored pkg/front_end's internal (unstable, under src/) API in-process.
// See the ADR for the full reasoning and what this defers.

import 'dart:io';

/// Compiles [dartSourcePath] to Kernel IR and returns the path to the
/// resulting `.dill`, inside a temp directory the caller owns — call
/// [KernelCompileResult.dispose] when done reading it.
///
/// Never modifies [dartSourcePath]. `dart compile kernel` requires a `main`
/// entry point, which a DCDart library file doesn't have — a synthetic
/// driver (`import '<source>' as target; void main() {}`) supplies one. A
/// bare, unused import is sufficient to retain the source library's members
/// in the emitted Kernel IR (verified empirically against this exact SDK
/// build — no call, no tear-off, needed — so this works uniformly for any
/// future DCDart source file regardless of its declarations' signatures,
/// without dcc-lower needing to know how to construct dummy arguments for
/// them).
Future<KernelCompileResult> compileToKernel(String dartSourcePath) async {
  final sourceFile = File(dartSourcePath);
  if (!sourceFile.existsSync()) {
    throw KernelFrontendError('source file not found: $dartSourcePath');
  }
  final sourceUri = sourceFile.absolute.uri;

  final tempDir = Directory.systemTemp.createTempSync('dcc_frontend_');
  final driverFile = File('${tempDir.path}/_dcc_driver.dart');
  driverFile.writeAsStringSync(
    "import '$sourceUri' as target;\nvoid main() {}\n",
  );
  final dillFile = File('${tempDir.path}/out.dill');

  // Platform.resolvedExecutable: the `dart` binary running dcc itself.
  // Robust against PATH not being set up in whatever shell invokes dcc —
  // this process could only have started if `dart` was findable at all.
  final result = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'kernel',
    '--no-link-platform',
    '-o',
    dillFile.path,
    driverFile.path,
  ]);

  if (result.exitCode != 0) {
    tempDir.deleteSync(recursive: true);
    throw KernelFrontendError(
      'dart compile kernel failed (exit ${result.exitCode}) for '
      '$dartSourcePath:\n${result.stdout}\n${result.stderr}',
    );
  }

  return KernelCompileResult._(dillFile.path, tempDir, sourceUri);
}

/// Result of [compileToKernel]. [dispose] must be called once the caller is
/// done reading [dillPath] — it owns a temp directory on disk.
class KernelCompileResult {
  final String dillPath;
  final Uri sourceUri;
  final Directory _tempDir;

  KernelCompileResult._(this.dillPath, this._tempDir, this.sourceUri);

  void dispose() {
    if (_tempDir.existsSync()) _tempDir.deleteSync(recursive: true);
  }
}

class KernelFrontendError extends Error {
  final String message;
  KernelFrontendError(this.message);

  @override
  String toString() => 'KernelFrontendError: $message';
}
