/* Original tests of the exact production picker state machine. No UIKit mock. */
#include "mng_preparation_selection.h"
#include <stdio.h>
#include <stdlib.h>
static void need(int yes){if(!yes){fputs("selection assertion failed\n",stderr);exit(1);}}
static const char job[]="0123456789abcdef0123456789abcdef";
static void route(unsigned mode,const char *identifier) {
    struct mng_preparation_selection s={0};
    need(mng_selection_begin(&s,identifier));uint64_t epoch=s.epoch;
    need(mng_selection_choose(&s,epoch,mode));
    need(mng_selection_bind(&s,epoch,11));need(mng_selection_picked(&s,11));
    if(mode==MNG_SELECT_PAIRED){need(s.stage==MNG_SELECT_UPDATE);need(mng_selection_bind(&s,epoch,12));need(mng_selection_picked(&s,12));}
    if(mode!=MNG_SELECT_ASSET_FOLDER){need(s.stage==MNG_SELECT_KEY_PROMPT);need(mng_selection_request_keys(&s,epoch));need(!mng_selection_request_keys(&s,epoch));need(s.stage==MNG_SELECT_KEYS);need(mng_selection_bind(&s,epoch,13));need(mng_selection_picked(&s,13));}
    char result[33];unsigned selected=0;
    need(mng_selection_take(&s,epoch,result,&selected));need(selected==mode);
    need(!strcmp(result,identifier?identifier:""));need(s.stage==MNG_SELECT_IDLE&&!s.picker&&!s.job[0]);
    memset(result,'x',sizeof(result));selected=99;
    need(!mng_selection_take(&s,epoch,result,&selected));need(result[0]=='x'&&selected==99);
}
int main(int argc,char **argv) {
    need(argc==2);
    if(!strcmp(argv[1],"routes")){
        for(unsigned mode=MNG_SELECT_BASE;mode<=MNG_SELECT_ASSET_FOLDER;mode++){route(mode,job);route(mode,NULL);}
    } else if(!strcmp(argv[1],"stale")) {
        struct mng_preparation_selection s={0};need(mng_selection_begin(&s,job));uint64_t old=s.epoch;
        need(mng_selection_choose(&s,old,MNG_SELECT_PAIRED));need(mng_selection_bind(&s,old,11));
        mng_selection_cancel(&s);need(mng_selection_begin(&s,NULL));uint64_t current=s.epoch;
        struct mng_preparation_selection before=s;
        need(!mng_selection_choose(&s,old,MNG_SELECT_BASE));need(!memcmp(&s,&before,sizeof(s)));
        need(mng_selection_choose(&s,current,MNG_SELECT_NCA_FOLDER));need(mng_selection_bind(&s,current,22));before=s;
        need(!mng_selection_owns(&s,11));need(!mng_selection_picked(&s,11));need(!mng_selection_bind(&s,old,33));need(!memcmp(&s,&before,sizeof(s)));
        need(mng_selection_picked(&s,22));need(s.stage==MNG_SELECT_KEY_PROMPT);before=s;
        need(!mng_selection_picked(&s,22));need(!memcmp(&s,&before,sizeof(s)));
        need(mng_selection_request_keys(&s,current));need(!mng_selection_is(&s,current,MNG_SELECT_KEY_PROMPT));need(!mng_selection_request_keys(&s,current));need(mng_selection_bind(&s,current,33));need(mng_selection_picked(&s,33));
        char result[33];unsigned mode=0;need(!mng_selection_take(&s,old,result,&mode));need(mng_selection_take(&s,current,result,&mode));need(!result[0]&&mode==MNG_SELECT_NCA_FOLDER);
    } else if(!strcmp(argv[1],"reserve")) {
        struct mng_preparation_selection s={0};
        /* Reserve before a host navigation transition. Returning to the game
         * screen sees a nonidle flow even before the mode sheet is presented. */
        need(mng_selection_begin(&s,job));uint64_t reserved=s.epoch;
        need(s.stage!=MNG_SELECT_IDLE&&!strcmp(s.job,job));
        need(mng_selection_is(&s,reserved,MNG_SELECT_MODE));
        need(!mng_selection_begin(&s,job));
        /* A canceled transition invalidates its delayed completion. */
        mng_selection_cancel(&s);need(mng_selection_begin(&s,NULL));
        need(!mng_selection_choose(&s,reserved,MNG_SELECT_PAIRED));
        need(mng_selection_choose(&s,s.epoch,MNG_SELECT_ASSET_FOLDER));need(!s.job[0]);
    } else if(!strcmp(argv[1],"cancel")) {
        for(unsigned stage=MNG_SELECT_SOURCE;stage<=MNG_SELECT_KEY_PROMPT;stage++) {
            struct mng_preparation_selection s={0};need(mng_selection_begin(&s,job));uint64_t old=s.epoch;
            s.stage=stage;s.picker=stage==MNG_SELECT_SOURCE?11:0;mng_selection_cancel(&s);
            need(s.stage==MNG_SELECT_IDLE&&!s.picker&&!s.mode&&!s.job[0]);need(!mng_selection_is(&s,old,stage));
            need(mng_selection_begin(&s,job));need(s.epoch!=old);need(!mng_selection_picked(&s,11));
        }
    } else if(!strcmp(argv[1],"reuse")) {
        struct mng_preparation_selection s={0};char title[]="0100123456780000",generation[65];memset(generation,'a',64);generation[64]=0;
        need(mng_selection_begin_reuse(&s,title,generation,101));uint64_t epoch=s.epoch;
        title[0]='f';generation[0]='b';need(!strcmp(s.reuse_title,"0100123456780000")&&s.reuse_generation[0]=='a'&&!s.job[0]);
        struct mng_preparation_selection before=s;need(!mng_selection_choose(&s,epoch,MNG_SELECT_BASE));need(!memcmp(&s,&before,sizeof(s)));
        need(!mng_selection_origin_is(&s,epoch,102));need(mng_selection_origin_is(&s,epoch,101));
        need(mng_selection_choose(&s,epoch,MNG_SELECT_PAIRED));
        need(mng_selection_bind(&s,epoch,11));need(mng_selection_picked(&s,11));need(s.stage==MNG_SELECT_UPDATE);
        need(mng_selection_bind(&s,epoch,12));need(mng_selection_picked(&s,12));need(mng_selection_request_keys(&s,epoch));
        need(mng_selection_bind(&s,epoch,13));need(mng_selection_picked(&s,13));
        char old_job[33];unsigned mode=0;need(!mng_selection_take(&s,epoch,old_job,&mode));
        struct mng_preparation_request out;memset(&out,'x',sizeof(out));
        need(!mng_selection_take_request(&s,epoch,0,&out)&&out.job[0]=='x');
        need(!mng_selection_take_request(&s,epoch,102,&out)&&out.job[0]=='x');
        need(mng_selection_take_request(&s,epoch,101,&out));need(out.mode==MNG_SELECT_PAIRED&&!out.job[0]);
        need(!strcmp(out.reuse_title,"0100123456780000")&&out.reuse_generation[0]=='a'&&out.reuse_generation[64]==0);
        need(!s.origin&&!s.reuse_title[0]&&!s.reuse_generation[0]&&s.stage==MNG_SELECT_IDLE);
        memset(&out,'x',sizeof(out));need(!mng_selection_take_request(&s,epoch,101,&out)&&out.job[0]=='x');
    } else if(!strcmp(argv[1],"reuse-cancel")) {
        char generation[65];memset(generation,'a',64);generation[64]=0;
        for(unsigned stage=MNG_SELECT_SOURCE;stage<=MNG_SELECT_KEY_PROMPT;stage++) {
            struct mng_preparation_selection s={0};need(mng_selection_begin_reuse(&s,"0100123456780000",generation,101));uint64_t old=s.epoch;
            s.stage=stage;s.picker=11;mng_selection_cancel(&s);
            need(!s.origin&&!s.reuse_title[0]&&!s.reuse_generation[0]&&!s.job[0]&&!s.picker);
            need(mng_selection_begin(&s,job));need(!s.origin&&!s.reuse_title[0]&&!s.reuse_generation[0]);
            need(!mng_selection_origin_is(&s,old,101));need(!mng_selection_picked(&s,11));
            uint64_t epoch=s.epoch;need(mng_selection_choose(&s,epoch,MNG_SELECT_ASSET_FOLDER));need(mng_selection_bind(&s,epoch,22));need(mng_selection_picked(&s,22));
            struct mng_preparation_request out;need(mng_selection_take_request(&s,epoch,0,&out));
            need(!strcmp(out.job,job)&&!out.reuse_title[0]&&!out.reuse_generation[0]&&out.mode==MNG_SELECT_ASSET_FOLDER);
        }
    } else if(!strcmp(argv[1],"reuse-invalid")) {
        struct mng_preparation_selection s={0},before=s;char generation[65];memset(generation,'a',64);generation[64]=0;
        const char *bad_titles[]={NULL,"","0000000000000000","010012345678000","01001234567800000","010012345678000F","010012345678000g"};
        for(unsigned i=0;i<sizeof(bad_titles)/sizeof(*bad_titles);i++){need(!mng_selection_begin_reuse(&s,bad_titles[i],generation,101));need(!memcmp(&s,&before,sizeof(s)));}
        need(!mng_selection_begin_reuse(&s,"0100123456780000",NULL,101));need(!mng_selection_begin_reuse(&s,"0100123456780000","aa",101));
        generation[0]='A';need(!mng_selection_begin_reuse(&s,"0100123456780000",generation,101));generation[0]='a';
        need(!mng_selection_begin_reuse(&s,"0100123456780000",generation,0));need(!memcmp(&s,&before,sizeof(s)));
        need(mng_selection_begin(&s,job));before=s;need(!mng_selection_begin_reuse(&s,"0100123456780000",generation,101));need(!memcmp(&s,&before,sizeof(s)));
    } else {
        need(!strcmp(argv[1],"invalid"));
        const char *bad[]={"","0123","0123456789abcdef0123456789abcde","0123456789abcdef0123456789abcdef0","0123456789abcdef0123456789abcdeF","0123456789abcdef0123456789abcdeg"};
        struct mng_preparation_selection s={0},before=s;
        for(unsigned i=0;i<sizeof(bad)/sizeof(*bad);i++){need(!mng_selection_job_valid(bad[i]));need(!mng_selection_begin(&s,bad[i]));need(!memcmp(&s,&before,sizeof(s)));}
        need(!mng_selection_job_valid(NULL));need(mng_selection_begin(&s,job));uint64_t epoch=s.epoch;before=s;
        need(!mng_selection_begin(&s,NULL));need(!mng_selection_choose(&s,epoch,0));need(!mng_selection_choose(&s,epoch,5));need(!mng_selection_bind(&s,epoch,11));need(!memcmp(&s,&before,sizeof(s)));
        need(mng_selection_choose(&s,epoch,MNG_SELECT_BASE));need(!mng_selection_bind(&s,epoch,0));need(mng_selection_bind(&s,epoch,11));need(!mng_selection_bind(&s,epoch,12));need(!mng_selection_owns(&s,0));
        mng_selection_cancel(&s);s.epoch=UINT64_MAX;before=s;need(!mng_selection_begin(&s,job));need(!memcmp(&s,&before,sizeof(s)));mng_selection_cancel(&s);need(s.epoch==UINT64_MAX&&!s.stage);
    }
    puts("{\"passed\":true}");return 0;
}
