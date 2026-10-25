#define _POSIX_C_SOURCE 200809L
#include "mng_container.h"
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

struct reader { FILE *file; uint64_t size; unsigned calls, fail_call; };
static int read_at(void *context,uint64_t offset,void *buffer,size_t length) {
    struct reader *r=context;
    if (++r->calls==r->fail_call || offset>r->size || length>r->size-offset ||
        offset>INT64_MAX || fseeko(r->file,(off_t)offset,SEEK_SET)) return -1;
    return fread(buffer,1,length,r->file)==length ? 0:-1;
}
int main(int argc,char **argv) {
    if (argc<2 || argc>3) return 2;
    struct reader reader={0};
    reader.file=fopen(argv[1],"rb");
    struct stat st;
    if (!reader.file || fstat(fileno(reader.file),&st) || st.st_size<0) return 2;
    reader.size=(uint64_t)st.st_size;
    if (argc==3) reader.fail_call=(unsigned)strtoul(argv[2],NULL,10);
    struct mng_inventory result={0};
    enum mng_status s=mng_container_inspect(read_at,&reader,reader.size,&result);
    printf("%u %u %zu\n",(unsigned)s,(unsigned)result.kind,result.count);
    if (s!=MNG_OK && (result.entries || result.names || result.count)) return 3;
    for (size_t i=0;i<result.count;i++) {
        printf("%" PRIu64 " %" PRIu64 " ",result.entries[i].offset,result.entries[i].size);
        const unsigned char *name=(const unsigned char *)result.entries[i].name;
        for (;*name;name++) printf("%02x",*name);
        putchar('\n');
    }
    mng_inventory_free(&result);
    mng_inventory_free(&result); /* release is idempotent */
    fclose(reader.file);
    return 0;
}
