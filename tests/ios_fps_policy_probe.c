#include "../games/totk/runtime/ios_fps_policy.h"
#include "../games/totk/third_party/d2r_gfx/gfx/nvn/nvn_pace.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    const unsigned rates[]={20,24,30,40,60,90,120};
    for (unsigned i=0;i<sizeof(rates)/sizeof(*rates);i++) {
        unsigned fps=rates[i];
        assert(ios_fps_supported(fps,120,1,0));
        assert(!ios_fps_supported(fps,120,0,0));
        assert(!ios_fps_supported(fps,120,1,1));
        uint64_t period=1000000000ull/fps;
        assert(ios_fps_cap_period(1000000000ull/120,period)==period);
        assert(ios_fps_cap_period(1000000000ull/15,period)==1000000000ull/15);
        nvn_pacer pacer={0};uint64_t now=1000000000ull;
        assert(!nvn_pace(&pacer,now,period));
        for(unsigned frame=0;frame<100;frame++) {
            uint64_t wait=nvn_pace(&pacer,now+1000000,period);
            assert(wait==period-1000000);
            now+=period;
        }
        now+=period*3;assert(!nvn_pace(&pacer,now,period));assert(pacer.target==now);
    }
    for (unsigned fps=90;fps<=120;fps+=30) {
        uint64_t cap=1000000000ull/fps;
        /* The production high-cap branch must bypass a guest interval=2 at 120 Hz. */
        assert(ios_fps_present_period(2*1000000000ull/120,cap,1)==cap);
        assert(ios_fps_present_period(1000000000ull/30,cap,0)==1000000000ull/30);
        assert(!ios_fps_supported(fps,60,1,0));
        assert(ios_fps_effective(fps,60)==60);
        assert(ios_fps_effective(fps,120)==fps);
    }
    assert(ios_fps_supported(90,90,1,0));assert(!ios_fps_supported(120,90,1,0));
    assert(ios_fps_present_period(1000000000ull/30,1000000000ull/60,1)==1000000000ull/30);
    assert(ios_fps_present_period(1000000000ull/30,1000000000ull/20,1)==1000000000ull/20);
    assert(ios_fps_present_period(123,0,1)==123);
    assert(ios_fps_supported(20,60,1,0));assert(!ios_fps_supported(24,60,1,0));
    assert(ios_fps_effective(24,120)==24);assert(ios_fps_effective(24,60)==60);
    assert(ios_fps_effective(20,60)==20);assert(ios_fps_effective(30,0)==60);
    assert(ios_fps_supported(30,60,1,0));assert(ios_fps_supported(60,60,1,0));
    assert(!ios_fps_supported(40,60,1,0));assert(!ios_fps_supported(40,0,1,0));
    assert(!ios_fps_supported(50,120,1,0));assert(!ios_fps_supported(0,120,1,0));
    assert(ios_fps_effective(40,120)==40);assert(ios_fps_effective(40,60)==60);
    assert(ios_fps_effective(0,120)==60);assert(ios_fps_effective(240,120)==60);
    assert(ios_fps_cap_period(123,0)==123);
    puts("PASS");return 0;
}
