/* Original fixture attestation. Production uses canopy_host.m after the actual
 * CanopyShaderCache verification while holding its immutable-seed lease. */
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
static unsigned digest_calls;
static unsigned char *counted_digest(const void *data,CC_LONG size,unsigned char *output) {
    digest_calls++;return CC_SHA256(data,size,output);
}
#define CC_SHA256 counted_digest
#import "totk_shader_seed.h"
#undef CC_SHA256
#include <stdio.h>
#include <string.h>
#if defined(CANOPY_HOST_RUNTIME)
static const char *trusted_path;
int runtime_canopy_shader_seed_verified(const char *path) {
    return trusted_path && path && !strcmp(trusted_path,path);
}
#endif
int main(int argc,char **argv) {
    @autoreleasepool {
        if(argc!=4)return 2;
#if defined(CANOPY_HOST_RUNTIME)
        trusted_path=!strcmp(argv[1],"trusted")?argv[2]:NULL;
#endif
        NSError *error=nil;
        NSDictionary *result=totk_seed_import(@(argv[2]),@(argv[3]),&error);
        if(!result){fprintf(stderr,"seed import failed\n");return 1;}
        /* Also compile the complete fill importer under both configurations. */
        if(!strcmp(argv[1],"never-fill"))result=totk_fill_import(@(argv[2]),@(argv[3]));
        NSMutableDictionary *report=[result mutableCopy];report[@"fixture_digest_calls"]=@(digest_calls);
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];
        if(!json)return 3;
        fwrite(json.bytes,1,json.length,stdout);putchar('\n');
    }
    return 0;
}
