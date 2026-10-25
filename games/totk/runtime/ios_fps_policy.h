#pragma once
#include <stdint.h>

static inline int ios_fps_valid(unsigned fps) { return fps == 20 || fps == 24 || fps == 30 || fps == 40 || fps == 60; }
static inline int ios_fps_supported(unsigned fps, unsigned maximum, int realtime_profile, int interpolation) {
    return ios_fps_valid(fps) && realtime_profile && !interpolation && maximum >= fps && maximum % fps == 0;
}
static inline unsigned ios_fps_effective(unsigned requested, unsigned maximum) {
    if (!ios_fps_valid(requested)) return 60;
    return maximum < requested || maximum % requested ? 60 : requested;
}
/* Extend the existing present deadline; never add a second timer or accelerate a slower guest interval. */
static inline uint64_t ios_fps_cap_period(uint64_t period, uint64_t cap_period) {
    return period < cap_period ? cap_period : period;
}
