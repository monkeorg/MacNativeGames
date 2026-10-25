/* Original Canopy host control flow; no SDK/game implementation or payload. */
#ifndef CANOPY_SDK_RETURN_H
#define CANOPY_SDK_RETURN_H
#include <stdint.h>
/* This is the native loader wrapper's result, not a guest program exit code. */
enum canopy_loader_result {
    CANOPY_LOADER_OK=0,
    CANOPY_LOADER_UNEXPECTED_SDK_RETURN=70
};
typedef void (*canopy_sdk_callback)(void);
typedef void (*canopy_sdk_start_fn)(uint64_t,uint64_t,canopy_sdk_callback,canopy_sdk_callback,canopy_sdk_callback);
/* Forward the existing five-argument Start call exactly. No callback is invoked
 * by the adapter, no thread is exited, and no resource is destroyed. A Start
 * that does not return cannot manufacture a completed/error return here. */
static inline enum canopy_loader_result canopy_call_sdk_start(canopy_sdk_start_fn start,uint64_t handle,
    canopy_sdk_callback ready,canopy_sdk_callback inits,canopy_sdk_callback finis) {
    start(handle,0,ready,inits,finis);
    return CANOPY_LOADER_UNEXPECTED_SDK_RETURN;
}
#endif
