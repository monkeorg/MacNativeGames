#ifndef CANOPY_INPROCESS_CROSS_H
#define CANOPY_INPROCESS_CROSS_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Version 1. Caller owns valid, nonoverlapping buffers for this synchronous call.
 * Status: 0 success, 1 invalid input, 2 output too small, 3 translation failure.
 * out_length is zero on error except status2 reports required UTF8 bytes.
 * No NUL terminator is included. No exception crosses this boundary. */
int canopy_spirv_cross(const uint8_t *spirv, size_t length,
                      uint8_t *output, size_t capacity, size_t *out_length);
/* Static NativeAOT ABI, same buffer ownership. JSON request uses service keys
 * plus chain (no code path); output {spirv_base64,metal,reflection}.
 * Additional statuses: 4 busy, 5 bounded request/output quota exceeded.
 * Function never executes shader code or publishes cache files. */
uint32_t canopy_shader_abi_version(void);
int canopy_shader_translate(const uint8_t *code, size_t code_length,
    const uint8_t *request, size_t request_length,
    uint8_t *output, size_t capacity, size_t *out_length);
#ifdef __cplusplus
}
#endif
#endif
