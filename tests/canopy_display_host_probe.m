#import <Foundation/Foundation.h>
#include "canopy_host.h"
#include <stdio.h>
#include <string.h>
int main(void){@autoreleasepool {
    struct mng_display_state state={MNG_DISPLAY_ABI,sizeof(state),99,{0}};
    if(canopy_host_read_display_state(&state)||state.validation!=MNG_DISPLAY_NOT_CONFIGURED)return 1;
    // A callback alone cannot claim a selected display or an actual session.
    canopy_host_game_patches_validated();
    if(canopy_host_read_display_state(&state)||state.validation!=MNG_DISPLAY_NOT_CONFIGURED)return 2;
    struct mng_display_state bad={MNG_DISPLAY_ABI+1,sizeof(bad),99,{0}},before=bad;
    if(!canopy_host_read_display_state(&bad)||memcmp(&bad,&before,sizeof(bad)))return 3;
    if(!canopy_host_read_display_state(NULL))return 4;
    puts("{\"status\":\"pass\",\"scope\":\"actual host query without native entry; no GPU evidence\"}");
}return 0;}
