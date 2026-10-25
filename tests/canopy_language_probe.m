#import <Foundation/Foundation.h>
#include "language.h"
#include "canopy_host.h"
#include <stdio.h>
static void need(BOOL yes){if(!yes){fputs("Foundation language fixture failed\n",stderr);exit(1);}}
int main(int argc,char **argv){@autoreleasepool {
    need(argc>=3);const char *mode=argv[1],*expected=argv[2];
    if(!strcmp(mode,"reset")) {
        const char *keys[]={"TOTK_FAST_MATH","TOTK_SHADER_XLATE","TOTK_SHADER_SERVICE","TOTK_SHADER_DEBUGMODE",
            "TOTK_MFX","TOTK_MFX_UPSCALE","TOTK_MFX_OUTPUT","TOTK_ANISO","DM_NVN_NOFXAA",NULL};
        for(unsigned i=0;keys[i];i++)need(!setenv(keys[i],"original-test-override",1));
        need(!setenv("TOTK_TAA","1",1));need(!canopy_host_pin_compile_environment());
        for(unsigned i=0;keys[i];i++){need(!getenv(keys[i]));}
        need(getenv("TOTK_TAA")&&!strcmp(getenv("TOTK_TAA"),"1"));
    } else {
        need(!strcmp(mode,"preferred"));need(!setenv("TOTK_LANG","",1));
        need(!runtime_language_apply_preferred_choice("",0));need(!getenv("TOTK_LANG"));
        char resolved[8];need(!runtime_language_resolve(getenv("TOTK_LANG"),getenv("TOTK_LOCALE"),1,resolved));need(!strcmp(resolved,expected));
        need(!setenv("TOTK_LANG","ko",1));need(!runtime_language_apply_preferred_choice("de",1));need(!strcmp(getenv("TOTK_LANG"),"ko"));
        need(!runtime_language_apply_preferred_choice("de",0));need(!strcmp(getenv("TOTK_LANG"),"de"));
    }
    puts("{\"passed\":true}");return 0;
}}
