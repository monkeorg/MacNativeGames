/* Original implementation of published format facts; reference and limits:
 * docs/ipados-save-format-research.md. No third-party implementation copied. */
#include "mng_totk_save.h"
#include <string.h>

static uint32_t word(const unsigned char *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
enum mng_totk_save_status mng_totk_save_inspect(const void *bytes,size_t length,
    struct mng_totk_save_preview *out) {
    if(!bytes||!out)return MNG_TOTK_SAVE_INVALID;
    if(length!=MNG_TOTK_SAVE_REFERENCE_SIZE)return MNG_TOTK_SAVE_SIGNATURE;
    const unsigned char *data=bytes;
    if(word(data)!=UINT32_C(0x01020304)||word(data+4)!=UINT32_C(0x0049e946)||
        word(data+8)!=UINT32_C(0x0003c138))return MNG_TOTK_SAVE_SIGNATURE;
    struct mng_totk_save_preview result={0};int found=0,terminated=0;
    for(size_t at=0x28;at+8<=length;at+=8) {
        uint32_t tag=word(data+at);
        if(tag==UINT32_C(0xa3db7114)){result.terminator_offset=at;terminated=1;break;}
        if(tag==UINT32_C(0xa77921d7)) {
            if(found)return MNG_TOTK_SAVE_STRUCTURE;
            result.wallet=word(data+at+4);result.wallet_value_offset=at+4;found=1;
        }
    }
    if(!found||!terminated)return MNG_TOTK_SAVE_STRUCTURE;
    if(result.wallet>MNG_TOTK_SAVE_REFERENCE_POLICY_MAX)return MNG_TOTK_SAVE_POLICY;
    *out=result;return MNG_TOTK_SAVE_OK;
}
enum mng_totk_save_status mng_totk_save_candidate(const void *source,size_t length,
    uint32_t wallet,void *destination,size_t capacity) {
    if(!source||!destination||capacity!=MNG_TOTK_SAVE_REFERENCE_SIZE)return MNG_TOTK_SAVE_INVALID;
    if(wallet>MNG_TOTK_SAVE_REFERENCE_POLICY_MAX)return MNG_TOTK_SAVE_POLICY;
    struct mng_totk_save_preview preview;
    enum mng_totk_save_status status=mng_totk_save_inspect(source,length,&preview);
    if(status!=MNG_TOTK_SAVE_OK)return status;
    uintptr_t src=(uintptr_t)source,dst=(uintptr_t)destination;
    if(src>UINTPTR_MAX-length||dst>UINTPTR_MAX-length || (src<dst+length&&dst<src+length))return MNG_TOTK_SAVE_INVALID;
    memcpy(destination,source,length);
    unsigned char *value=(unsigned char *)destination+preview.wallet_value_offset;
    for(unsigned i=0;i<4;i++)value[i]=(unsigned char)(wallet>>(i*8));
    return MNG_TOTK_SAVE_OK;
}
