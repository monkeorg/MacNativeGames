#include "../games/totk/runtime/ios_fps_policy.h"
#include "../games/totk/third_party/d2r_gfx/gfx/nvn/nvn_pace.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    for (unsigned fps=30;fps<=60;fps+=10) {
        if(fps==50)continue;
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
    assert(ios_fps_supported(30,60,1,0));assert(ios_fps_supported(60,60,1,0));
    assert(!ios_fps_supported(40,60,1,0));assert(!ios_fps_supported(40,0,1,0));
    assert(!ios_fps_supported(50,120,1,0));assert(!ios_fps_supported(0,120,1,0));
    assert(ios_fps_effective(40,120)==40);assert(ios_fps_effective(40,60)==60);
    assert(ios_fps_effective(0,120)==60);assert(ios_fps_effective(240,120)==60);
    assert(ios_fps_cap_period(123,0)==123);
    puts("PASS");return 0;
}
