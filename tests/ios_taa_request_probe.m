#import "totk_taa.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
int main(void) {
    unsetenv("TOTK_TAA");
    assert(!taa_enabled());assert(!taa_active());
    taa_set_enabled(1);assert(taa_enabled());assert(!taa_active());
    taa_frame_end();assert(taa_active());
    taa_set_enabled(0);assert(!taa_enabled());assert(taa_active());
    taa_frame_end();assert(!taa_active());
    taa_set_enabled(2);assert(!taa_enabled());
    taa_set_enabled(-1);assert(!taa_enabled());
    taa_toggle();assert(taa_enabled());taa_frame_end();assert(taa_active());
    puts("PASS");return 0;
}
