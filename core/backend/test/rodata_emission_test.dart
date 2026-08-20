// Emission tests for read-only static data (ADR-0040).
//
// WHY THIS FILE EXISTS AT ALL, and why it is in backend/ rather than being a
// conformance target: `DCConstAddrOf` — a global holding the ADDRESS of
// another global — is UNREACHABLE from DCDart source today. `@rodata`
// requires a `final` field with a `const` initializer, and a `const`
// initializer cannot reference a `final` field, so no table can name another
// one. The node exists so that adding the all-`const` surface later is an
// extension rather than an IR redesign.
//
// An IR node no surface can reach is a node nothing exercises, and it will
// quietly stop working before the thing that needs it arrives. So these
// tests build the shapes directly and assert what comes out.
import 'package:backend/llvm_emit.dart';
import 'package:dc_ir/dc_ir.dart';
import 'package:test/test.dart';

DCModule moduleWith(List<DCGlobal> globals) => DCModule(
      name: 'test',
      functions: const [],
      globals: globals,
    );

void main() {
  test('a u64 table emits a bare [N x i64] with no header and explicit align', () {
    final ll = emitModule(
      moduleWith([
        DCGlobal(
          linkName: 'memmap',
          initializer: const DCConstArray(DCInt.u64, [
            DCConstInt(DCInt.u64, 4096),
            DCConstInt(DCInt.u64, 8192),
          ]),
          alignBytes: 8,
        ),
      ]),
    );
    expect(
      ll,
      contains(
        '@memmap = internal constant [2 x i64] [i64 4096, i64 8192], align 8',
      ),
    );
    // The layout guarantee the kernel reads through a raw pointer: nothing
    // may precede element 0. A length word or class pointer would silently
    // shift every index rather than fail.
    expect(ll, isNot(contains('i64 2, i64 4096')));
  });

  test('narrower widths emit at their own width', () {
    final ll = emitModule(
      moduleWith([
        DCGlobal(
          linkName: 'bytes',
          initializer: const DCConstArray(DCInt.u8, [
            DCConstInt(DCInt.u8, 1),
            DCConstInt(DCInt.u8, 2),
          ]),
          alignBytes: 1,
        ),
      ]),
    );
    expect(ll, contains('@bytes = internal constant [2 x i8] [i8 1, i8 2], align 1'));
  });

  test('globals are NOT unnamed_addr — identical ones must not be merged', () {
    // unnamed_addr moves a global into a mergeable section, which lets the
    // linker collapse two byte-identical globals to ONE ADDRESS. For a type
    // descriptor, whose address IS its identity, that would make two
    // distinct types indistinguishable.
    final ll = emitModule(
      moduleWith([
        DCGlobal(
          linkName: 'a',
          initializer: const DCConstArray(DCInt.u64, [DCConstInt(DCInt.u64, 7)]),
          alignBytes: 8,
        ),
        DCGlobal(
          linkName: 'b',
          initializer: const DCConstArray(DCInt.u64, [DCConstInt(DCInt.u64, 7)]),
          alignBytes: 8,
        ),
      ]),
    );
    expect(ll, isNot(contains('unnamed_addr')));
    expect(ll, contains('@a = internal constant'));
    expect(ll, contains('@b = internal constant'));
  });

  test('a global holding other globals\' addresses emits ptr elements', () {
    final ll = emitModule(
      moduleWith([
        DCGlobal(
          linkName: 'names',
          initializer: const DCConstArray(DCInt.u8, [DCConstInt(DCInt.u8, 65)]),
          alignBytes: 1,
        ),
        DCGlobal(
          linkName: 'directory',
          initializer: const DCConstArray(DCInt.usize, [
            DCConstAddrOf('names'),
          ]),
          alignBytes: 8,
        ),
      ]),
    );
    // `[1 x ptr]`, NOT `[1 x i64]`: the element type comes from the ELEMENTS,
    // because a relocation is a pointer regardless of the pointer-sized
    // integer type the table was labelled with. Labelling it i64 makes clang
    // reject the constant outright ("got '[1 x ptr]' but expected
    // '[1 x i64]'") -- loud, but only because LLVM type-checks constants.
    expect(ll, contains('[1 x ptr] [ptr @names]'));
  });

  test('a MIXED array is rejected -- an LLVM array is homogeneous', () {
    // This is the shape a real type descriptor wants:
    //     { ptr name, i64 fieldCount, ptr fields }
    // That is a STRUCT, not an array, and struct constants are not
    // implemented (known-gaps GAP-0031). Rejected here with a specific
    // message rather than handed to clang to refuse with a worse one.
    expect(
      () => emitModule(
        moduleWith([
          DCGlobal(
            linkName: 'descriptor',
            initializer: const DCConstArray(DCInt.u64, [
              DCConstAddrOf('names'),
              DCConstInt(DCInt.u64, 1),
            ]),
            alignBytes: 8,
          ),
        ]),
      ),
      throwsA(isA<BackendError>()),
    );
  });

  test('an address-of leaf with a byte offset emits a getelementptr', () {
    final ll = emitModule(
      moduleWith([
        DCGlobal(
          linkName: 'table',
          initializer: const DCConstArray(DCInt.u64, [
            DCConstAddrOf('base', offsetBytes: 16),
          ]),
          alignBytes: 8,
        ),
      ]),
    );
    expect(ll, contains('getelementptr (i8, ptr @base, i64 16)'));
  });

  test('a global colliding with an ARC arena name is rejected, not emitted', () {
    // linkName goes out verbatim (spec §9) with no mangling, so nothing
    // downstream would catch this collision.
    expect(
      () => emitModule(
        moduleWith([
          DCGlobal(
            linkName: 'dc_free_top',
            initializer: const DCConstArray(DCInt.u64, [DCConstInt(DCInt.u64, 0)]),
            alignBytes: 8,
          ),
        ]),
      ),
      throwsA(isA<BackendError>()),
    );
  });
}
