/* Public synthetic tests only. Production callers use the native APIs directly. */
#include "mng_content.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* Only mng_content.c's test object redirects memcmp here. Reset before binding
 * to measure candidate-index work independently of parser validation. */
static uint64_t comparisons;
int content_probe_memcmp(const void *left,const void *right,size_t n) {
    comparisons++;return memcmp(left,right,n);
}
static unsigned char *load(const char *name,size_t limit,size_t *size) {
    FILE *f=fopen(name,"rb");if (!f) return NULL;
    if (fseek(f,0,SEEK_END)) { fclose(f);return NULL; }
    long n=ftell(f);
    if (n<0 || (unsigned long)n>limit || fseek(f,0,SEEK_SET)) { fclose(f);return NULL; }
    unsigned char *bytes=malloc(n ? (size_t)n:1);
    if (!bytes || fread(bytes,1,(size_t)n,f)!=(size_t)n) { free(bytes);fclose(f);return NULL; }
    fclose(f);*size=(size_t)n;return bytes;
}
static uint64_t u64(const unsigned char *p) {
    uint64_t n=0;for (unsigned i=0;i<8;i++) n|=(uint64_t)p[i]<<(8*i);return n;
}
static void hex(const unsigned char *p,size_t n) { for (size_t i=0;i<n;i++) printf("%02x",p[i]); }
int main(int argc,char **argv) {
    struct mng_content *meta[256]={0};size_t count=0;
    struct mng_content_candidate *candidates=NULL;size_t candidates_count=0;
    enum mng_content_status status=MNG_CONTENT_INVALID;
    struct mng_content_plan plan, before;memset(&plan,0xa5,sizeof(plan));memcpy(&before,&plan,sizeof(plan));
    int parse=argc==4 && !strcmp(argv[1],"parse");
    int bind=argc==5 && !strcmp(argv[1],"bind");
    int planning=argc>=7 && !strcmp(argv[1],"plan") && (argc-5)%2==0;
    if (!parse && !planning && !bind) return 2;
    if (parse || bind) count=1;else count=(size_t)(argc-5)/2;
    if (count>256) return 2;
    for (size_t i=0;i<count;i++) {
        size_t n=0;int arg=planning ? 5+(int)i*2:2;
        unsigned char *data=load(argv[arg],1024*1024+1,&n);
        if (!data) return 3;
        status=mng_content_parse(argv[arg+1],data,n,&meta[i]);free(data);
        if (status) goto done;
    }
    if (!parse) {
        size_t n=0;
        unsigned char *raw=load(argv[4],16385u*57,&n);
        if (!raw || n%57) { free(raw);status=MNG_CONTENT_INVALID;goto done; }
        candidates_count=n/57;candidates=calloc(candidates_count ? candidates_count:1,sizeof(*candidates));
        if (!candidates) { free(raw);status=MNG_CONTENT_NOMEM;goto done; }
        for (size_t i=0;i<candidates_count;i++) {
            memcpy(candidates[i].id,raw+i*57,16);memcpy(candidates[i].sha256,raw+i*57+16,32);
            candidates[i].size=u64(raw+i*57+48);candidates[i].nca_type=raw[i*57+56];
        }
        free(raw);
        comparisons=0;
        if (bind) status=mng_content_bind(meta[0],candidates,candidates_count);
        else status=mng_content_plan((const struct mng_content *const *)meta,count,candidates,candidates_count,
            strtoull(argv[2],NULL,16),(uint32_t)strtoul(argv[3],NULL,10),&plan);
    }
done:
    printf("{\"status\":\"%s\"",mng_content_status_name(status));
    if (!parse) printf(",\"comparisons\":%" PRIu64,comparisons);
    if (!status && parse) {
        printf(",\"title\":\"%016" PRIx64 "\",\"application\":\"%016" PRIx64 "\",\"patch\":\"%016" PRIx64 "\",\"type\":%u,\"version\":%" PRIu32 ",\"requiredApplication\":%" PRIu32 ",\"contents\":[",
            meta[0]->title_id,meta[0]->application_id,meta[0]->patch_id,meta[0]->type,meta[0]->version,meta[0]->required_application_version);
        for (size_t i=0;i<meta[0]->content_count;i++) {
            const struct mng_content_record *r=meta[0]->contents+i;
            printf("%s{\"id\":\"",i ? ",":"");hex(r->id,16);printf("\",\"sha256\":\"");hex(r->sha256,32);
            printf("\",\"size\":%" PRIu64 ",\"role\":%u,\"idOffset\":%u}",r->size,r->role,r->id_offset);
        }
        printf("]");
    }
    if (planning) {
        printf(",\"outputUnchanged\":%s",memcmp(&plan,&before,sizeof(plan)) ? "false":"true");
        if (!status) {
            printf(",\"base\":%zu,\"patch\":",plan.base_index);
            if (plan.patch_index==SIZE_MAX) printf("null");else printf("%zu",plan.patch_index);
            printf(",\"version\":%" PRIu32 ",\"dlc\":[",plan.version);
            for (size_t i=0;i<plan.dlc_count;i++) printf("%s%zu",i ? ",":"",plan.dlc_indices[i]);
            printf("]");
        }
    }
    printf("}\n");
    free(candidates);for (size_t i=0;i<count;i++) mng_content_free(meta[i]);return 0;
}
