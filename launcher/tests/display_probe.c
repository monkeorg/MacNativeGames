#include "mng_display.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void check(int yes){if(!yes){fprintf(stderr,"display contract failed\n");exit(1);}}
static struct mng_display_profile profile(unsigned flags){return (struct mng_display_profile){MNG_DISPLAY_ABI,sizeof(struct mng_display_profile),flags};}
static struct mng_display_resolution resolve(unsigned flags,unsigned height,unsigned aspect,double w,double h){
    struct mng_display_profile p=profile(flags);struct mng_display_resolution r={0};
    check(!mng_display_resolve(&p,height,aspect,w,h,&r));check(!mng_display_check(&p,&r.config,w,h));return r;
}
static void invalid(void){
    struct mng_display_profile p=profile(3);struct mng_display_resolution sentinel,result;memset(&sentinel,0x5a,sizeof(sentinel));
    const double dimensions[][2]={{NAN,768},{1024,INFINITY},{0,768},{1024,-1},{32769,768},{1024,0}};
    for(unsigned i=0;i<sizeof(dimensions)/sizeof(*dimensions);i++){result=sentinel;check(mng_display_resolve(&p,1080,1,dimensions[i][0],dimensions[i][1],&result));check(!memcmp(&result,&sentinel,sizeof(result)));}
    const unsigned flags[]={2,4,0xffffffffu};
    for(unsigned i=0;i<sizeof(flags)/sizeof(*flags);i++){p=profile(flags[i]);result=sentinel;check(mng_display_resolve(&p,720,0,1024,768,&result));check(!memcmp(&result,&sentinel,sizeof(result)));}
    p=profile(3);p.abi++;result=sentinel;check(mng_display_resolve(&p,720,0,1024,768,&result));check(!memcmp(&result,&sentinel,sizeof(result)));
    p=profile(3);p.size--;check(mng_display_resolve(&p,720,0,1024,768,&result));
    p=profile(3);check(mng_display_resolve(&p,721,0,1024,768,&result));check(mng_display_resolve(&p,720,2,1024,768,&result));
    check(mng_display_resolve(NULL,720,0,1024,768,&result));check(mng_display_resolve(&p,720,0,1024,768,NULL));
}
static void tamper(void){
    struct mng_display_profile p=profile(3);struct mng_display_resolution r=resolve(3,1080,1,1024,768);
    struct mng_display_config original=r.config;
    uint32_t *fields[]={&r.config.abi,&r.config.size,&r.config.width,&r.config.height,&r.config.aspect,&r.config.experimental,&r.config.fixed_resolution};
    for(unsigned i=0;i<sizeof(fields)/sizeof(*fields);i++){r.config=original;(*fields[i])++;check(mng_display_check(&p,&r.config,1024,768));}
    check(mng_display_check(&p,&original,1194,834));check(mng_display_check(NULL,&original,1024,768));check(mng_display_check(&p,NULL,1024,768));
}
int main(int argc,char **argv){
    if(argc!=2)return 2;
    const char *mode=argv[1];
    if(!strcmp(mode,"stock")){
        struct mng_display_resolution r=resolve(0,720,0,1024,768);
        check(r.config.width==1280&&r.config.height==720&&!r.config.fixed_resolution&&!r.config.experimental&&!r.height_outcome&&!r.aspect_outcome);
    }else if(!strcmp(mode,"stock-fallback")){
        struct mng_display_resolution r=resolve(0,1080,1,1024,768);
        check(r.config.width==1280&&r.config.height==720&&r.config.aspect==0&&r.height_outcome==MNG_DISPLAY_UNSUPPORTED&&r.aspect_outcome==MNG_DISPLAY_UNSUPPORTED);
    }else if(!strcmp(mode,"wide")){
        struct mng_display_resolution r=resolve(1,1080,0,2436,1125);
        check(r.config.width==1920&&r.config.height==1080&&r.config.fixed_resolution&&!r.config.experimental&&!r.height_outcome&&!r.aspect_outcome);
        r=resolve(1,1080,1,1024,768);check(r.aspect_outcome==MNG_DISPLAY_UNSUPPORTED&&r.config.width==1920);
    }else if(!strcmp(mode,"four-three")){
        struct mng_display_resolution r=resolve(3,1080,1,1024,768);
        check(r.config.width==1440&&r.config.height==1080&&r.config.aspect==1&&r.config.experimental&&r.config.fixed_resolution&&!r.aspect_outcome);
        r=resolve(3,720,1,1024,768);check(r.config.width==960&&r.config.height==720);
    }else if(!strcmp(mode,"other-ratios")){
        const double views[][2]={{1194,834},{1600,1000},{768,1024},{2436,1125},{1024,768.01}};
        for(unsigned i=0;i<sizeof(views)/sizeof(*views);i++){struct mng_display_resolution r=resolve(3,1080,1,views[i][0],views[i][1]);check(r.config.width==1920&&r.config.aspect==0&&r.aspect_outcome==MNG_DISPLAY_UNSUPPORTED&&!r.config.experimental);}
    }else if(!strcmp(mode,"invalid"))invalid();else if(!strcmp(mode,"tamper"))tamper();else return 2;
    puts("{\"status\":\"pass\",\"scope\":\"startup configuration only, no frame or GPU evidence\"}");return 0;
}
