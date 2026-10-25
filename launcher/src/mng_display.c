#include "mng_display.h"
#include <math.h>
#include <stddef.h>
static int profile_valid(const struct mng_display_profile *p) {
    return p && p->abi==MNG_DISPLAY_ABI && p->size==sizeof(*p) &&
        !(p->flags&~(MNG_DISPLAY_SCENE_1080|MNG_DISPLAY_FOUR_THREE)) &&
        (!(p->flags&MNG_DISPLAY_FOUR_THREE)||(p->flags&MNG_DISPLAY_SCENE_1080));
}
int mng_display_resolve(const struct mng_display_profile *profile,uint32_t height,uint32_t aspect,
    double width,double view_height,struct mng_display_resolution *out) {
    if(!out||!profile_valid(profile)||(height!=720&&height!=1080)||aspect>MNG_DISPLAY_FULL||
        !isfinite(width)||!isfinite(view_height)||width<=0||view_height<=0||width>32768||view_height>32768)return -1;
    struct mng_display_resolution result={0};
    if(height==1080&&!(profile->flags&MNG_DISPLAY_SCENE_1080)){height=720;result.height_outcome=MNG_DISPLAY_UNSUPPORTED;}
    if(aspect==MNG_DISPLAY_FULL&&(!(profile->flags&MNG_DISPLAY_FOUR_THREE)||width*3!=view_height*4)){
        aspect=MNG_DISPLAY_16_9;result.aspect_outcome=MNG_DISPLAY_UNSUPPORTED;
    }
    result.config=(struct mng_display_config){MNG_DISPLAY_ABI,sizeof(result.config),height*(aspect==MNG_DISPLAY_FULL?4u:16u)/(aspect==MNG_DISPLAY_FULL?3u:9u),
        height,aspect,aspect==MNG_DISPLAY_FULL,(profile->flags&MNG_DISPLAY_SCENE_1080)!=0};
    *out=result;return 0;
}
int mng_display_check(const struct mng_display_profile *profile,const struct mng_display_config *config,double width,double height) {
    if(!config||config->abi!=MNG_DISPLAY_ABI||config->size!=sizeof(*config))return -1;
    struct mng_display_resolution resolved={0};
    if(mng_display_resolve(profile,config->height,config->aspect,width,height,&resolved)||
        resolved.height_outcome!=MNG_DISPLAY_SUPPORTED||resolved.aspect_outcome!=MNG_DISPLAY_SUPPORTED)return -1;
    const struct mng_display_config *expected=&resolved.config;
    return config->width==expected->width&&config->height==expected->height&&config->aspect==expected->aspect&&
        config->experimental==expected->experimental&&config->fixed_resolution==expected->fixed_resolution?0:-1;
}
