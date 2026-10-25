#ifndef CANOPY_INPROCESS_CROSS_H
#define CANOPY_INPROCESS_CROSS_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Additive control contract v1,64-bit hosts. The host owns this immutable
 * struct and callback/context for the ENTIRE synchronous call. Callback is
 * synchronous, serialized, nonreentrant and must not throw. Nonzero cancels.
 * These pointers NEVER originate in request JSON. Zero quotas mean bounded
 * defaults, positive quotas may only LOWER the implementation ceilings:
 *64M work units,262144 tracked nodes,256MiB tracked growth,5000ms.
 * Tracked growth is instrumented allocation/growth, NOT a hard process heap
 * limit or sandbox. Time and cancellation are cooperative at checkpoints. */
struct canopy_shader_control {
    uint32_t version,size;
    uint64_t reserved;
    uint64_t max_work,max_nodes,max_tracked_allocation_bytes;
    uint32_t timeout_ms,reserved2;
    int (*cancel)(void *context);
    void *context;
};
#if defined(__cplusplus)
static_assert(sizeof(void *)==8 && sizeof(canopy_shader_control)==64,"control ABI");
static_assert(offsetof(canopy_shader_control,cancel)==48 && offsetof(canopy_shader_control,context)==56,"control ABI offsets");
#else
_Static_assert(sizeof(void *)==8 && sizeof(struct canopy_shader_control)==64,"control ABI");
_Static_assert(offsetof(struct canopy_shader_control,cancel)==48 && offsetof(struct canopy_shader_control,context)==56,"control ABI offsets");
#endif
/* Version 1. Caller owns valid, nonoverlapping buffers for this synchronous call.
 * Status:0success,1invalid input,2output too small,3translation failure,
 *5cooperative quota/deadline,6cancelled by controlled host checkpoint.
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
/* Same ABI1 payload/ownership; old entry uses identical bounded defaults.
 * Status6=cancelled,5=quota/deadline. Every failure is redacted and leaves
 * caller output untouched; out_length=0 except required size on status2. */
int canopy_shader_translate_controlled(const uint8_t *code,size_t code_length,
    const uint8_t *request,size_t request_length,uint8_t *output,size_t capacity,
    size_t *out_length,const struct canopy_shader_control *control);
/* Private in-process checkpoint adapter; zero means continue,5/6 stop. Shares
 * the caller's ONE request budget across all Cross calls/retries. */
typedef int (*canopy_budget_checkpoint)(void *context,uint64_t work,uint64_t nodes,uint64_t bytes);
int canopy_spirv_cross_controlled(const uint8_t *spirv,size_t length,uint8_t *output,
    size_t capacity,size_t *out_length,canopy_budget_checkpoint checkpoint,void *context);
#ifdef __cplusplus
}
#endif
#endif
