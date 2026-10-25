/* Original locale/choice fixtures over the exact production helper. */
#include "language.h"
#include <stdio.h>
static void need(int yes){if(!yes){fputs("language fixture failed\n",stderr);exit(1);}}
static void code(const char *explicit_code,const char *locale,int brazil,const char *expected) {
    char out[8];memset(out,'x',sizeof(out));need(!runtime_language_resolve(explicit_code,locale,brazil,out));
    char padded[8]={0};memcpy(padded,expected,strlen(expected));need(!memcmp(out,padded,sizeof(out)));need(out[0]!=0);
}
int main(int argc,char **argv) {
    need(argc==2);
    if(!strcmp(argv[1],"system")) {
        code(NULL,NULL,0,"en-US");code("","",0,"en-US");code("","unknown-ZZ",0,"en-US");
        code("","de-DE",0,"de");code(NULL,"JA_jp.UTF-8",0,"ja");code(NULL,"fr-CA",0,"fr");code(NULL,"en-GB",0,"en-US");
        code("","ko-KR",0,"ko");code(NULL,"ru_RU@calendar=gregorian",0,"ru");
    } else if(!strcmp(argv[1],"chinese")) {
        const char *traditional[]={"zh-Hant","zh-Hant-TW","zh-TW","zh-HK","zh-MO","ZH_hAnT_cn","zh_HK.UTF-8","zh-TW-u-ca-chinese"};
        for(unsigned i=0;i<sizeof(traditional)/sizeof(*traditional);i++)code("",traditional[i],0,"zh-Hant");
        const char *simplified[]={"zh","zh-CN","zh-SG","zh-Hans","zh-Hans-TW","zh-Hans-HK","zh-u-hk"};
        for(unsigned i=0;i<sizeof(simplified)/sizeof(*simplified);i++)code(NULL,simplified[i],0,"zh-Hans");
    } else if(!strcmp(argv[1],"brazil")) {
        code(NULL,"pt-BR",0,"pt");code(NULL,"pt-BR",1,"pt-BR");code("","PT_br",1,"pt-BR");
        code(NULL,"pt-PT",1,"pt");code(NULL,"pt-PT-u-rg-brzzzz",1,"pt");code("pt-BR","en-US",0,"pt-BR");
    } else if(!strcmp(argv[1],"explicit")) {
        const char *choices[]={"ja","en-US","fr","de","it","es","zh-CN","ko","nl","pt","ru","zh-TW","en-GB","fr-CA","es-419","zh-Hans","zh-Hant","pt-BR"};
        for(unsigned i=0;i<sizeof(choices)/sizeof(*choices);i++)code(choices[i],"zh-Hant-TW",0,choices[i]);
        code("zz","de-DE",0,"zz"); /* Existing developer spelling policy. */
    } else if(!strcmp(argv[1],"bounds")) {
        char out[8];memset(out,'x',sizeof(out));need(runtime_language_resolve("12345678","en-US",0,out)==-1);
        for(unsigned i=0;i<sizeof(out);i++){need(out[i]=='x');}
        need(runtime_language_resolve(NULL,NULL,0,NULL)==-1);
        char long_tag[129];memset(long_tag,'a',128);long_tag[128]=0;code(NULL,long_tag,0,"en-US");
        code(NULL,"zh-!HK",0,"en-US");code(NULL,"-zh",0,"en-US");code(NULL,"abcdefghijklmnoo-TW",0,"en-US");
    } else {
        need(!strcmp(argv[1],"environment"));
        need(!setenv("TOTK_LANG","de",1));need(!runtime_language_bind_locale("zh-Hant-TW"));
        need(!runtime_language_apply_choice("",0));need(getenv("TOTK_LANG")==NULL);code(getenv("TOTK_LANG"),getenv("TOTK_LOCALE"),0,"zh-Hant");
        need(!runtime_language_apply_choice("ja",0));code(getenv("TOTK_LANG"),getenv("TOTK_LOCALE"),0,"ja");
        need(!setenv("TOTK_LANG","ko",1));need(!runtime_language_apply_choice("de",1));need(!strcmp(getenv("TOTK_LANG"),"ko"));
        need(!setenv("TOTK_LANG","",1));need(!runtime_language_apply_choice("",1));need(!getenv("TOTK_LANG"));code(getenv("TOTK_LANG"),getenv("TOTK_LOCALE"),0,"zh-Hant");
        need(!runtime_language_bind_locale(NULL));need(!getenv("TOTK_LOCALE"));code(NULL,getenv("TOTK_LOCALE"),0,"en-US");
        need(!setenv("TOTK_LANG","ja",1));need(runtime_language_apply_choice("12345678",0)==-1);need(!strcmp(getenv("TOTK_LANG"),"ja"));
    }
    puts("{\"passed\":true}");return 0;
}
