/* Original host-to-renderer device handoff. No game-specific graphics behavior. */
#ifndef CANOPY_METAL_DEVICE_H
#define CANOPY_METAL_DEVICE_H
#import <Metal/Metal.h>
#if defined(CANOPY_HOST_RUNTIME)
/* Main-thread, single-use binding. Nil and replacement with a different device
 * are rejected. The host retains the exact selected object for process life. */
int canopy_host_bind_metal_device(id<MTLDevice> device);
id<MTLDevice> runtime_canopy_metal_device(void);
#endif
static inline id<MTLDevice> canopy_renderer_metal_device(void) {
#if defined(CANOPY_HOST_RUNTIME)
    /* No default-device fallback: shader identity and renderer must agree. */
    return runtime_canopy_metal_device();
#else
    return MTLCreateSystemDefaultDevice();
#endif
}
#endif
