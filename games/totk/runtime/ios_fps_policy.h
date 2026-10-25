#pragma once
#include <stdint.h>

static inline int ios_fps_valid(unsigned fps) { return fps == 20 || fps == 24 || fps == 30 || fps == 40 || fps == 60 || fps == 90 || fps == 120; }
static inline int ios_fps_display_supported(unsigned fps, unsigned maximum) {
    return ios_fps_valid(fps) && maximum >= fps && (fps >= 90 || maximum % fps == 0);
}
static inline int ios_fps_supported(unsigned fps, unsigned maximum, int realtime_profile, int interpolation) {
    return ios_fps_display_supported(fps,maximum) && realtime_profile && !interpolation;
}
static inline unsigned ios_fps_effective(unsigned requested, unsigned maximum) {
    if (!ios_fps_valid(requested)) return 60;
    return !ios_fps_display_supported(requested,maximum) ? 60 : requested;
}
/* Extend the existing present deadline; never add a second timer or accelerate a slower guest interval. */
static inline uint64_t ios_fps_cap_period(uint64_t period, uint64_t cap_period) {
    return period < cap_period ? cap_period : period;
}
/* Explicit high caps use the existing real-time clock, including a guest interval of two.
   Original timing, interpolation, and required 30 FPS movie pacing keep their base period. */
static inline uint64_t ios_fps_present_period(uint64_t period, uint64_t cap_period, int realtime_uncapped) {
    if (realtime_uncapped && cap_period && cap_period < 1000000000ull / 60) return cap_period;
    return ios_fps_cap_period(period,cap_period);
}
