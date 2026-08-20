/* c_side.c -- the OTHER object file.
 *
 * Every symbol here is declared `@extern external` in extern_calls.dart and
 * defined nowhere in DCDart. Compiled to its own `.o` and handed to the
 * linker alongside dcc's output; the DCDart object does not become a program
 * without it.
 *
 * FREESTANDING ON PURPOSE: no #include beyond <stdint.h> (types only, no
 * symbols), no libc call, no global constructor. The freestanding leg of
 * tests/conformance/ffi-extern/run.sh links this with `-nostdlib`, which is
 * the configuration oscortex_core actually needs. `libc_calls.dart` covers
 * the "symbol nobody in this project wrote" case separately.
 */
#include <stdint.h>

uint64_t dcx_add(uint64_t a, uint64_t b) { return a + b; }

uint64_t dcx_answer(void) { return 42; }

/* Deliberately does enough work that a wrong-width prototype would show up
 * in the value rather than accidentally agreeing on small inputs. */
uint32_t dcx_mix32(uint32_t a, uint32_t b) {
    return (a * 2654435761u) ^ (b + 0x9E3779B9u);
}

uint8_t dcx_clamp8(uint8_t value) { return value > 200 ? 200 : value; }

uint64_t dcx_widen(uint8_t low, uint32_t mid, uint64_t high) {
    return (uint64_t)low + ((uint64_t)mid << 8) + (high << 40);
}

/* The void case, with a real, observable side effect: the harness reads
 * dcx_last_recorded back to prove the call actually happened rather than
 * being optimized into nothing. */
uint64_t dcx_last_recorded = 0;
uint64_t dcx_record_count = 0;

void dcx_record(uint64_t value) {
    dcx_last_recorded = value;
    dcx_record_count += 1;
}

/* Struct returned BY VALUE across the ABI boundary. This layout is DCDart's
 * `Result` (docs/decisions/0014-result-value-representation.md): tag 0 = Ok,
 * tag 1 = Err, payload alongside. Two 64-bit fields, which is a
 * two-register return on both SysV-AMD64 and AAPCS64. */
typedef struct {
    uint64_t tag;
    uint64_t payload;
} dcx_result;

dcx_result dcx_checked(uint64_t value) {
    dcx_result r;
    if (value == 0) {
        r.tag = 1;
        r.payload = 999;
    } else {
        r.tag = 0;
        r.payload = value + 1;
    }
    return r;
}
