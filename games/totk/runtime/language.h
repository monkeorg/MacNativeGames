#ifndef TOTK_RUNTIME_LANGUAGE_H
#define TOTK_RUNTIME_LANGUAGE_H
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

/* The runtime's existing Switch language-code representation: eight bytes,
 * zero padded, with at most seven nonzero bytes. Validated launcher choices
 * and nonempty developer overrides retain their exact historical spelling.
 * Empty explicit values mean System, never an empty guest language code. */
static inline unsigned runtime_language_length(const char *text,unsigned limit) {
    unsigned n=0;if(text)while(n<limit&&text[n])n++;return n;
}
static inline char runtime_language_lower(char c){return c>='A'&&c<='Z'?(char)(c+'a'-'A'):c;}
static inline int runtime_language_alpha(char c){c=runtime_language_lower(c);return c>='a'&&c<='z';}
static inline const char *runtime_language_system(const char *tag,int brazil_supported) {
    unsigned length=runtime_language_length(tag,128);if(!tag||!length||length==128)return "en-US";
    char language[16]={0},script[5]={0},region[3]={0};unsigned token=0,position=0;
    while(position<length && tag[position]!='@' && tag[position]!='.') {
        unsigned start=position;
        while(position<length && tag[position]!='-' && tag[position]!='_' && tag[position]!='@' && tag[position]!='.') {
            char c=tag[position];if(!runtime_language_alpha(c)&&!(c>='0'&&c<='9'))return "en-US";position++;
        }
        unsigned n=position-start;if(!n)return "en-US";
        if(!token) {
            if(n>=sizeof(language))return "en-US";
            for(unsigned i=0;i<n;i++)language[i]=runtime_language_lower(tag[start+i]);
        } else {
            /* BCP47 singleton introduces extensions/private use. Extension
             * tokens must not replace the actual script or country. */
            if(n==1)break;
            if(n==4&&!script[0])for(unsigned i=0;i<4;i++)script[i]=runtime_language_lower(tag[start+i]);
            else if(n==2&&!region[0]&&runtime_language_alpha(tag[start])&&runtime_language_alpha(tag[start+1]))
                for(unsigned i=0;i<2;i++)region[i]=runtime_language_lower(tag[start+i]);
        }
        token++;if(position<length&&(tag[position]=='-'||tag[position]=='_'))position++;
    }
    if(!strcmp(language,"zh")) {
        if(!strcmp(script,"hant"))return "zh-Hant";
        if(!strcmp(script,"hans"))return "zh-Hans";
        return !strcmp(region,"tw")||!strcmp(region,"hk")||!strcmp(region,"mo")?"zh-Hant":"zh-Hans";
    }
    if(!strcmp(language,"pt"))return brazil_supported&&!strcmp(region,"br")?"pt-BR":"pt";
    /* Preserve existing non-Chinese locale canonicalization, rather than
     * inventing new per-title region/font support. All outputs are from the
     * existing settings_service.c native language-code list. */
    static const char *const simple[]={"ja","de","fr","es","it","nl","ru","ko"};
    for(unsigned i=0;i<sizeof(simple)/sizeof(*simple);i++)if(!strcmp(language,simple[i]))return simple[i];
    return "en-US";
}
/* Failure leaves all output bytes unchanged. Caller owns valid C strings. */
static inline int runtime_language_resolve(const char *explicit_code,const char *locale,int brazil_supported,char out[8]) {
    if(!out)return -1;
    unsigned n=runtime_language_length(explicit_code,8);if(n==8)return -1;
    const char *selected=n?explicit_code:runtime_language_system(locale,brazil_supported);
    char result[8]={0};memcpy(result,selected,strlen(selected));memcpy(out,result,sizeof(result));return 0;
}
/* These environment boundaries are used only by the original iOS launcher
 * and opt-in Canopy host. Mac callers retain their existing environment policy. */
static inline int runtime_language_bind_locale(const char *preferred) {
    unsigned n=runtime_language_length(preferred,128);if(n==128)return -1;
    return n?setenv("TOTK_LOCALE",preferred,1):unsetenv("TOTK_LOCALE");
}
static inline int runtime_language_apply_choice(const char *choice,int preserve_developer_override) {
    unsigned n=runtime_language_length(choice,8);if(n==8)return -1;
    const char *existing=getenv("TOTK_LANG");
    if(preserve_developer_override&&existing)return *existing?0:unsetenv("TOTK_LANG");
    return n?setenv("TOTK_LANG",choice,1):unsetenv("TOTK_LANG");
}
#ifdef __OBJC__
#import <Foundation/Foundation.h>
/* Actual per-app preference, not the regional formatting locale. This runs
 * before the guest starts; changing it after account/SDK initialization is not
 * advertised as live language application. */
static inline int runtime_language_apply_preferred_choice(const char *choice,int preserve_developer_override) {
    NSString *preferred=NSLocale.preferredLanguages.firstObject;
    if(runtime_language_bind_locale(preferred.UTF8String))return -1;
    return runtime_language_apply_choice(choice,preserve_developer_override);
}
#endif
#endif
