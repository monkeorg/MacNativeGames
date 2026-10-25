#include "mng_container.h"
#include <stdlib.h>
#include <string.h>

static uint32_t u32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}
static uint64_t u64(const unsigned char *p) { return u32(p) | (uint64_t)u32(p+4)<<32; }
static int fits(uint64_t start, uint64_t length, uint64_t bound) {
    return start <= bound && length <= bound-start;
}
static int empty(const struct mng_inventory *o) {
    return o && !o->entries && !o->names && !o->count;
}
void mng_inventory_free(struct mng_inventory *o) {
    if (o) { free(o->entries); free(o->names); memset(o,0,sizeof(*o)); }
}
/* Reject invalid UTF-8, overlong sequences, surrogate codepoints and unsafe
 * path components. A filename is one component, never an extraction path. */
static int valid_name(const unsigned char *p, size_t n) {
    if (!n || (n==1 && p[0]=='.') || (n==2 && p[0]=='.' && p[1]=='.')) return 0;
    for (size_t i=0; i<n;) {
        unsigned c=p[i++], extra, value, minimum;
        if (c=='/' || c=='\\' || c==0) return 0;
        if (c<128) continue;
        if (c>=0xc2 && c<=0xdf) { extra=1; value=c&31; minimum=0x80; }
        else if (c>=0xe0 && c<=0xef) { extra=2; value=c&15; minimum=0x800; }
        else if (c>=0xf0 && c<=0xf4) { extra=3; value=c&7; minimum=0x10000; }
        else return 0;
        if (extra>n-i) return 0;
        while (extra--) { c=p[i++]; if ((c&0xc0)!=0x80) return 0; value=(value<<6)|(c&63); }
        if (value<minimum || value>0x10ffff || (value>=0xd800 && value<=0xdfff)) return 0;
    }
    return 1;
}
static int by_name(const void *a,const void *b) {
    const struct mng_entry *x=*(const struct mng_entry *const *)a,*y=*(const struct mng_entry *const *)b;
    return strcmp(x->name,y->name);
}
static int by_offset(const void *a,const void *b) {
    const struct mng_entry *x=*(const struct mng_entry *const *)a,*y=*(const struct mng_entry *const *)b;
    if (x->offset!=y->offset) return x->offset<y->offset ? -1:1;
    /* Match stable on-disk order for zero-sized entries sharing an offset. */
    return x<y ? -1 : x>y;
}
enum mng_status mng_partition_inspect(mng_read_at read_at, void *context,
    uint64_t source_size, uint64_t offset, uint64_t bound,
    enum mng_kind kind, struct mng_inventory *output) {
    unsigned char header[16], *table=NULL;
    struct mng_entry **order=NULL;
    struct mng_inventory result={0};
    enum mng_status status=MNG_INVALID;
    if (!read_at || !empty(output) || (kind!=MNG_PFS0 && kind!=MNG_HFS0) ||
        !fits(offset,bound,source_size) || bound<16) return MNG_INVALID;
    if (read_at(context,offset,header,16)) return MNG_IO;
    if (memcmp(header,kind==MNG_PFS0 ? "PFS0":"HFS0",4)) return MNG_INVALID;
    uint32_t count=u32(header+4), strings=u32(header+8);
    if (count>MNG_MAX_ENTRIES || strings>MNG_MAX_STRINGS) return MNG_LIMIT;
    size_t stride=kind==MNG_PFS0 ? 24:64, table_size=(size_t)count*stride;
    uint64_t payload=16+(uint64_t)table_size+strings;
    if (payload>bound) return MNG_INVALID;
    result.kind=kind; result.count=count;
    /* Allocate one byte for empty tables so zero-length allocations are portable. */
    table=malloc(table_size ? table_size:1);
    result.names=malloc(strings ? strings:1);
    result.entries=calloc(count ? count:1,sizeof(*result.entries));
    order=calloc(count ? count:1,sizeof(*order));
    if (!table || !result.names || !result.entries || !order) { status=MNG_NOMEM; goto done; }
    if ((table_size && read_at(context,offset+16,table,table_size)) ||
        (strings && read_at(context,offset+16+table_size,result.names,strings))) { status=MNG_IO; goto done; }
    for (size_t i=0;i<count;i++) {
        const unsigned char *entry=table+i*stride;
        uint64_t relative=u64(entry), length=u64(entry+8);
        uint32_t nameoff=u32(entry+16);
        if (nameoff>=strings || !fits(relative,length,bound-payload)) goto done;
        const char *name=result.names+nameoff;
        size_t available=strings-nameoff;
        size_t scan=available>MNG_MAX_NAME+1 ? MNG_MAX_NAME+1:available;
        const char *end=memchr(name,0,scan);
        if (!end) { if (available>MNG_MAX_NAME) status=MNG_LIMIT; goto done; }
        size_t n=(size_t)(end-name);
        if (n>MNG_MAX_NAME) { status=MNG_LIMIT; goto done; }
        if (!valid_name((const unsigned char *)name,n)) goto done;
        result.entries[i]=(struct mng_entry){name,offset+payload+relative,length};
        order[i]=result.entries+i;
    }
    qsort(order,count,sizeof(*order),by_name);
    for (size_t i=1;i<count;i++) if (!strcmp(order[i-1]->name,order[i]->name)) goto done;
    qsort(order,count,sizeof(*order),by_offset);
    uint64_t end=offset+payload;
    for (size_t i=0;i<count;i++) {
        if (order[i]->offset<end) goto done;
        end=order[i]->offset+order[i]->size;
    }
    *output=result; memset(&result,0,sizeof(result)); status=MNG_OK;
done:
    free(table); free(order); mng_inventory_free(&result); return status;
}
enum mng_status mng_container_inspect(mng_read_at read_at, void *context,
    uint64_t source_size, struct mng_inventory *output) {
    unsigned char header[0x38];
    if (!read_at || !empty(output) || source_size<4) return MNG_INVALID;
    if (read_at(context,0,header,4)) return MNG_IO;
    if (!memcmp(header,"PFS0",4)) {
        enum mng_status s=mng_partition_inspect(read_at,context,source_size,0,source_size,MNG_PFS0,output);
        if (s==MNG_OK) output->kind=MNG_NSP;
        return s;
    }
    if (source_size<0x138) return MNG_INVALID;
    if (read_at(context,0x100,header,sizeof(header))) return MNG_IO;
    if (memcmp(header,"HEAD",4)) return MNG_INVALID;
    uint64_t root=u64(header+0x30);
    if (root>source_size) return MNG_INVALID;
    struct mng_inventory partitions={0};
    enum mng_status s=mng_partition_inspect(read_at,context,source_size,root,source_size-root,MNG_HFS0,&partitions);
    if (s!=MNG_OK) return s;
    const struct mng_entry *secure=NULL;
    for (size_t i=0;i<partitions.count;i++) if (!strcmp(partitions.entries[i].name,"secure")) secure=partitions.entries+i;
    if (secure) {
        s=mng_partition_inspect(read_at,context,source_size,secure->offset,secure->size,MNG_HFS0,output);
        if (s==MNG_OK) output->kind=MNG_XCI;
    } else s=MNG_INVALID;
    mng_inventory_free(&partitions); return s;
}
