/* Original artificial record buffers. Not a real-save compatibility fixture. */
#include "mng_totk_save.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void put(unsigned char *p,uint32_t value) {for(unsigned i=0;i<4;i++)p[i]=(unsigned char)(value>>(8*i));}
static void fixture(unsigned char *p) {
    memset(p,0,MNG_TOTK_SAVE_REFERENCE_SIZE);
    put(p,0x01020304);put(p+4,0x0049e946);put(p+8,0x0003c138);
    put(p+0x30,0xa77921d7);put(p+0x34,1234);put(p+0x40,0xa3db7114);
    memset(p+0x48,0x5a,MNG_TOTK_SAVE_REFERENCE_SIZE-0x48);
}
int main(int argc,char **argv) {
    assert(argc==2);const size_t size=MNG_TOTK_SAVE_REFERENCE_SIZE;
    unsigned char *source=malloc(size),*copy=malloc(size),*output=malloc(size);assert(source&&copy&&output);
    fixture(source);memcpy(copy,source,size);memset(output,0x71,size);
    struct mng_totk_save_preview preview={19,23,29},before=preview;
    if(!strcmp(argv[1],"roundtrip")) {
        assert(mng_totk_save_inspect(source,size,&preview)==0);
        assert(preview.wallet==1234&&preview.wallet_value_offset==0x34&&preview.terminator_offset==0x40);
        for(unsigned i=0;i<3;i++) {uint32_t value=i==0?0:i==1?999999:1234;
            assert(mng_totk_save_candidate(source,size,value,output,size)==0);
            assert(mng_totk_save_inspect(output,size,&preview)==0&&preview.wallet==value);
            assert(!memcmp(source,copy,size));assert(!memcmp(output,source,0x34)&&!memcmp(output+0x38,source+0x38,size-0x38));}
    } else if(!strcmp(argv[1],"signature")) {
        for(size_t length=0;length<=size+1;length=length==0?size-1:length+1) {
            if(length==size)continue;
            assert(mng_totk_save_inspect(source,length,&preview)!=0);assert(preview.wallet_value_offset==before.wallet_value_offset&&preview.terminator_offset==before.terminator_offset&&preview.wallet==before.wallet);}
        for(size_t at=0;at<12;at++){source[at]^=1;assert(mng_totk_save_inspect(source,size,&preview)!=0);source[at]^=1;}
    } else if(!strcmp(argv[1],"structure")) {
        put(source+0x38,0xa77921d7);assert(mng_totk_save_inspect(source,size,&preview)==MNG_TOTK_SAVE_STRUCTURE);
        fixture(source);put(source+0x30,0);assert(mng_totk_save_inspect(source,size,&preview)==MNG_TOTK_SAVE_STRUCTURE);
        fixture(source);put(source+0x40,0);assert(mng_totk_save_inspect(source,size,&preview)==MNG_TOTK_SAVE_STRUCTURE);
        fixture(source);put(source+0x28,0xa3db7114);assert(mng_totk_save_inspect(source,size,&preview)==MNG_TOTK_SAVE_STRUCTURE);
        fixture(source);put(source+0x34,1000000);assert(mng_totk_save_inspect(source,size,&preview)==MNG_TOTK_SAVE_POLICY);
        assert(preview.wallet_value_offset==before.wallet_value_offset&&preview.terminator_offset==before.terminator_offset&&preview.wallet==before.wallet);
    } else if(!strcmp(argv[1],"opaque")) {
        /* Marker-shaped payload and unaligned bytes are NOT an invented second
         * table. Unknown payload semantics remain outside this reader. */
        put(source+0x55,0xa77921d7);put(source+0x60,0xa3db7114);
        assert(mng_totk_save_inspect(source,size,&preview)==0&&preview.wallet==1234);
    } else if(!strcmp(argv[1],"refusal")) {
        assert(mng_totk_save_candidate(source,size,1000000,output,size)==MNG_TOTK_SAVE_POLICY);
        assert(mng_totk_save_candidate(source,size,0,output,size-1)==MNG_TOTK_SAVE_INVALID);
        assert(mng_totk_save_candidate(source,size,0,source,size)==MNG_TOTK_SAVE_INVALID);
        assert(mng_totk_save_candidate(source,size,0,source+1,size)==MNG_TOTK_SAVE_INVALID);
        assert(mng_totk_save_inspect(NULL,size,&preview)==MNG_TOTK_SAVE_INVALID);
        assert(mng_totk_save_inspect(source,size,NULL)==MNG_TOTK_SAVE_INVALID);
        source[0]^=1;assert(mng_totk_save_candidate(source,size,0,output,size)==MNG_TOTK_SAVE_SIGNATURE);
        for(size_t i=0;i<size;i++)assert(output[i]==0x71);
    } else assert(!"unknown mode");
    free(source);free(copy);free(output);puts("PASS");return 0;
}
