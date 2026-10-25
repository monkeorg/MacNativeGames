#include "mng_bktr.h"
#include "mng_crypto.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Original bounds-checked implementation from public format facts. Reference:
 * ISC hactool1d64a83450e025622f3468c28fc4164dad2c5ef6 bktr.h/nca.c and the
 * repository's build_app.py table-layout compatibility checks. BKTRv1 format
 * confirmed by public BucketTree declarations at Atmosphere6b0c077b (read only;
 * no GPL code copied). No hactool implementation/dependency is embedded. */
#define PAGE 0x4000u
#define CHUNK 65536u
#define ENTRY_LIMIT 262144u
#define TABLE_LIMIT (32u*1024u*1024u)
#define SOURCE_LIMIT (UINT64_C(128)<<30)
#define HASH_LIMIT (UINT64_C(64)<<20)
struct relocation { uint64_t start,end,physical;uint32_t patch; };
struct subsection { uint64_t start,end;uint32_t counter; };
struct table { uint64_t offset,size;uint32_t count; };
struct level { uint64_t offset,size;unsigned power; };
struct mng_bktr {
    struct mng_bktr_source base,patch;
    struct mng_bktr_callbacks callbacks;
    uint64_t section_offset,section_size,virtual_size,patch_data_end;
    unsigned char key[16],fs[512];
    struct relocation *relocations;
    struct subsection *subsections;
    size_t relocation_count,subsection_count;
    struct level levels[6];
    enum mng_bktr_status status;
    int verified;
};
static uint32_t u32(const unsigned char *p) { return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static uint64_t u64(const unsigned char *p) { return u32(p)|(uint64_t)u32(p+4)<<32; }
static int fits(uint64_t offset,uint64_t length,uint64_t bound) { return offset<=bound && length<=bound-offset; }
static int fail(struct mng_bktr *c,enum mng_bktr_status status) { c->status=status;c->verified=0;return -1; }
static int poll(struct mng_bktr *c) {
    if (c->status) return -1;
    if (c->callbacks.cancelled && c->callbacks.cancelled(c->callbacks.context)) return fail(c,MNG_BKTR_CANCELLED);
    if (c->callbacks.check_sources && c->callbacks.check_sources(c->callbacks.context)) return fail(c,MNG_BKTR_INTEGRITY);
    return 0;
}
static void progress(struct mng_bktr *c,const char *phase,uint64_t done,uint64_t total) {
    if (c->callbacks.progress) c->callbacks.progress(c->callbacks.context,phase,done,total);
}
/* Tables use the ordinary section CTR. Patch payload substitutes the subsection
 * generation in counter bytes4..7; low64bits are absolute NCA block position. */
static int physical_read(struct mng_bktr *c,uint64_t offset,void *output,size_t length,const uint32_t *generation) {
    if (!fits(offset,length,c->section_size)) return fail(c,MNG_BKTR_INVALID);
    unsigned char encrypted[CHUNK],counter[16]={0};
    for (unsigned i=0;i<8;i++) counter[i]=c->fs[0x147-i];
    if (generation) for (unsigned i=0;i<4;i++) counter[7-i]=(unsigned char)(*generation>>(8*i));
    unsigned char *to=output;
    int result=0;
    while (length) {
        size_t n=length>CHUNK ? CHUNK:length;
        uint64_t absolute=c->section_offset+offset;
        if (poll(c)) { result=-1;break; }
        if (c->patch.read_at(c->patch.context,absolute,encrypted,n)) { result=fail(c,MNG_BKTR_IO);break; }
        if (poll(c)) { result=-1;break; }
        if (mng_aes128_ctr(c->key,counter,absolute,encrypted,to,n)) { result=fail(c,MNG_BKTR_INVALID);break; }
        offset+=n;to+=n;length-=n;
    }
    mng_secure_clear(encrypted,sizeof(encrypted));mng_secure_clear(counter,sizeof(counter));return result;
}
static int table_header(struct mng_bktr *c,const unsigned char *bytes,struct table *table) {
    table->offset=u64(bytes);table->size=u64(bytes+8);table->count=u32(bytes+24);
    if (memcmp(bytes+16,"BKTR",4) || u32(bytes+20)!=1 || u32(bytes+28)) return fail(c,MNG_BKTR_UNSUPPORTED);
    if (!table->count || table->count>ENTRY_LIMIT || table->size>TABLE_LIMIT) return fail(c,MNG_BKTR_LIMIT);
    if (table->size<2*PAGE || table->size%PAGE || !fits(table->offset,table->size,c->section_size)) return fail(c,MNG_BKTR_INVALID);
    return 0;
}
static int read_table(struct mng_bktr *c,const struct table *table,int relocations,uint64_t *total) {
    unsigned char root[PAGE],leaf[PAGE];
    if (physical_read(c,table->offset,root,sizeof(root),NULL)) return -1;
    uint32_t buckets=u32(root+4);uint64_t end=u64(root+8);
    if (!buckets || buckets>(PAGE-16)/8 || u32(root) || !end || end>SOURCE_LIMIT ||
        table->size!=(uint64_t)(buckets+1)*PAGE) return fail(c,MNG_BKTR_INVALID);
    if (!relocations && end!=c->patch_data_end && end!=c->patch_data_end+u64(c->fs+0x108)) return fail(c,MNG_BKTR_INVALID);
    size_t entry_size=relocations ? 20:16,capacity=(PAGE-16)/entry_size,used=0;
    uint64_t previous=0;
    for (uint32_t bucket=0;bucket<buckets;bucket++) {
        uint64_t start=u64(root+16+8*bucket);
        uint64_t boundary=bucket+1<buckets ? u64(root+16+8*(bucket+1)):end;
        if ((!bucket && start) || start>=boundary || boundary>end ||
            (!relocations && start>=c->patch_data_end)) return fail(c,MNG_BKTR_INVALID);
        if (physical_read(c,table->offset+(uint64_t)(bucket+1)*PAGE,leaf,sizeof(leaf),NULL)) return -1;
        uint32_t count=u32(leaf+4);
        if (u32(leaf)!=bucket || !count || count>capacity || count>table->count-used || u64(leaf+8)!=boundary) return fail(c,MNG_BKTR_INVALID);
        for (uint32_t i=0;i<count;i++) {
            const unsigned char *raw=leaf+16+i*entry_size;
            uint64_t at=u64(raw);
            if ((i==0 && at!=start) || (used && at<=previous) || at>=boundary ||
                (!relocations && at>=c->patch_data_end)) return fail(c,MNG_BKTR_INVALID);
            if (relocations) {
                uint32_t patch=u32(raw+16);
                if (patch>1) return fail(c,MNG_BKTR_INVALID);
                c->relocations[used]=(struct relocation){at,0,u64(raw+8),patch};
            } else {
                if (u32(raw+8)) return fail(c,MNG_BKTR_UNSUPPORTED);
                c->subsections[used]=(struct subsection){at,0,u32(raw+12)};
            }
            previous=at;used++;
        }
        progress(c,relocations ? "bktr-relocations":"bktr-subsections",used,table->count);
    }
    if (used!=table->count) return fail(c,MNG_BKTR_INVALID);
    *total=end;return 0;
}
void mng_bktr_close(struct mng_bktr *c) {
    if (!c) return;
    free(c->relocations);free(c->subsections);mng_secure_clear(c,sizeof(*c));free(c);
}
enum mng_bktr_status mng_bktr_open(const struct mng_bktr_config *config,
    const struct mng_bktr_callbacks *callbacks,struct mng_bktr **out) {
    if (!out) return MNG_BKTR_INVALID;
    *out=NULL;
    if (!config || !config->fs_header || !config->base.read_at || !config->patch_nca.read_at ||
        !config->base.size || config->section_offset%512 || config->section_size%512 ||
        !fits(config->section_offset,config->section_size,config->patch_nca.size)) return MNG_BKTR_INVALID;
    if (config->base.size>SOURCE_LIMIT || config->patch_nca.size>SOURCE_LIMIT) return MNG_BKTR_LIMIT;
    const unsigned char *fs=config->fs_header;
    if (fs[2]!=0 || fs[3]!=3 || fs[4]!=4 || memcmp(fs+8,"IVFC",4) ||
        u32(fs+12)!=0x20000 || u32(fs+16)!=32 || u32(fs+20)!=7) return MNG_BKTR_UNSUPPORTED;
    struct mng_bktr *c=calloc(1,sizeof(*c));if (!c) return MNG_BKTR_NOMEM;
    c->base=config->base;c->patch=config->patch_nca;c->section_offset=config->section_offset;c->section_size=config->section_size;
    memcpy(c->key,config->key,16);memcpy(c->fs,fs,512);if (callbacks) c->callbacks=*callbacks;
    struct table reloc={0},subs={0};
    if (poll(c) || table_header(c,fs+0x100,&reloc) || table_header(c,fs+0x120,&subs)) goto bad;
    if (reloc.size>TABLE_LIMIT-subs.size) { fail(c,MNG_BKTR_LIMIT);goto bad; }
    if (!reloc.offset || reloc.offset+reloc.size!=subs.offset ||
        subs.offset+subs.size>c->section_size || (c->section_size-subs.offset-subs.size)%512) {
        fail(c,MNG_BKTR_INVALID);goto bad;
    }
    c->patch_data_end=reloc.offset;c->relocation_count=reloc.count;c->subsection_count=subs.count;
    c->relocations=calloc(reloc.count,sizeof(*c->relocations));c->subsections=calloc(subs.count,sizeof(*c->subsections));
    if (!c->relocations || !c->subsections) { fail(c,MNG_BKTR_NOMEM);goto bad; }
    uint64_t subsection_total;
    if (read_table(c,&reloc,1,&c->virtual_size) || read_table(c,&subs,0,&subsection_total)) goto bad;
    for (size_t i=0;i<c->relocation_count;i++) {
        struct relocation *r=c->relocations+i;
        r->end=i+1<c->relocation_count ? c->relocations[i+1].start:c->virtual_size;
        uint64_t bound=r->patch ? c->patch_data_end:c->base.size;
        if (r->start>=r->end || !fits(r->physical,r->end-r->start,bound)) { fail(c,MNG_BKTR_INVALID);goto bad; }
    }
    for (size_t i=0;i<c->subsection_count;i++) {
        struct subsection *s=c->subsections+i;
        s->end=i+1<c->subsection_count ? c->subsections[i+1].start:c->patch_data_end;
        if (s->start>=s->end) { fail(c,MNG_BKTR_INVALID);goto bad; }
    }
    for (unsigned i=0;i<6;i++) {
        const unsigned char *raw=fs+0x18+24*i;
        struct level *level=c->levels+i;
        *level=(struct level){u64(raw),u64(raw+8),u32(raw+16)};
        if (level->power<12 || level->power>24 || u32(raw+20)) { fail(c,MNG_BKTR_UNSUPPORTED);goto bad; }
        if (!level->size || !fits(level->offset,level->size,c->virtual_size)) { fail(c,MNG_BKTR_INVALID);goto bad; }
        if (level->size>(i==5 ? (UINT64_C(64)<<30):HASH_LIMIT)) { fail(c,MNG_BKTR_LIMIT);goto bad; }
        for (unsigned j=0;j<i;j++) if (level->offset<c->levels[j].offset+c->levels[j].size &&
            c->levels[j].offset<level->offset+level->size) { fail(c,MNG_BKTR_INVALID);goto bad; }
        uint64_t blocks=level->size/(UINT64_C(1)<<level->power)+(level->size%(UINT64_C(1)<<level->power)!=0);
        if (blocks>(i ? c->levels[i-1].size:32)/32) { fail(c,MNG_BKTR_INVALID);goto bad; }
    }
    if (poll(c)) goto bad;
    *out=c;return MNG_BKTR_OK;
bad:;
    enum mng_bktr_status status=c->status;mng_bktr_close(c);return status;
}
uint64_t mng_bktr_size(const struct mng_bktr *c) { return c ? c->virtual_size:0; }
enum mng_bktr_status mng_bktr_status(const struct mng_bktr *c) { return c ? c->status:MNG_BKTR_INVALID; }
static size_t relocation_at(const struct mng_bktr *c,uint64_t offset) {
    size_t left=0,right=c->relocation_count;
    while (left<right) { size_t middle=left+(right-left)/2;
        if (c->relocations[middle].start<=offset) left=middle+1;else right=middle; }
    return left-1; /* First start==0, and caller checked offset<virtual_size. */
}
static size_t subsection_at(const struct mng_bktr *c,uint64_t offset) {
    size_t left=0,right=c->subsection_count;
    while (left<right) { size_t middle=left+(right-left)/2;
        if (c->subsections[middle].start<=offset) left=middle+1;else right=middle; }
    return left-1;
}
int mng_bktr_read_at(void *context,uint64_t offset,void *output,size_t length) {
    struct mng_bktr *c=context;
    if (!c) return -1;
    if (poll(c)) return -1;
    if ((!output && length) || !fits(offset,length,c->virtual_size)) return fail(c,MNG_BKTR_INVALID);
    unsigned char *to=output;
    while (length) {
        if (poll(c)) return -1;
        const struct relocation *r=c->relocations+relocation_at(c,offset);
        uint64_t physical=r->physical+offset-r->start;
        size_t n=length>CHUNK ? CHUNK:length;
        if (n>r->end-offset) n=(size_t)(r->end-offset);
        if (r->patch) {
            const struct subsection *s=c->subsections+subsection_at(c,physical);
            if (n>s->end-physical) n=(size_t)(s->end-physical);
            if (physical_read(c,physical,to,n,&s->counter)) return -1;
        } else {
            if (c->base.read_at(c->base.context,physical,to,n)) return fail(c,MNG_BKTR_IO);
            if (poll(c)) return -1;
        }
        offset+=n;to+=n;length-=n;
    }
    return poll(c);
}
static int hash_block(struct mng_bktr *c,uint64_t offset,uint64_t size,uint64_t padded,unsigned char digest[32]) {
    struct mng_sha256 *hash=NULL;unsigned char bytes[CHUNK];uint64_t at=0;
    if (mng_sha256_init(&hash)) return fail(c,MNG_BKTR_NOMEM);
    int bad=0;
    while (at<size) {
        size_t n=size-at>CHUNK ? CHUNK:(size_t)(size-at);
        if (mng_bktr_read_at(c,offset+at,bytes,n)) { bad=1;break; }
        if (mng_sha256_update(hash,bytes,n)) { fail(c,MNG_BKTR_INTEGRITY);bad=1;break; }
        at+=n;
    }
    memset(bytes,0,sizeof(bytes));
    while (!bad && at<padded) {
        size_t n=padded-at>CHUNK ? CHUNK:(size_t)(padded-at);
        if (poll(c)) { bad=1;break; }
        if (mng_sha256_update(hash,bytes,n)) { fail(c,MNG_BKTR_INTEGRITY);bad=1;break; }
        at+=n;
    }
    if (!bad && mng_sha256_final(hash,digest)) { fail(c,MNG_BKTR_INTEGRITY);bad=1; }
    mng_sha256_free(hash);mng_secure_clear(bytes,sizeof(bytes));return bad ? -1:0;
}
enum mng_bktr_status mng_bktr_verify_ivfc(struct mng_bktr *c) {
    if (!c) return MNG_BKTR_INVALID;
    if (poll(c)) return c->status;
    c->verified=0;
    for (unsigned i=0;i<6;i++) {
        const struct level *level=c->levels+i;
        uint64_t block=UINT64_C(1)<<level->power,count=level->size/block+(level->size%block!=0);
        char phase[32];(void)snprintf(phase,sizeof(phase),"verify-bktr-ivfc-%u",i);
        for (uint64_t index=0;index<count;index++) {
            unsigned char actual[32],expected[32];
            uint64_t n=level->size-index*block;if (n>block) n=block;
            if (i) { if (mng_bktr_read_at(c,c->levels[i-1].offset+index*32,expected,32)) return c->status; }
            else memcpy(expected,c->fs+0xc8,32);
            if (hash_block(c,level->offset+index*block,n,block,actual)) return c->status;
            if (memcmp(actual,expected,32)) { fail(c,MNG_BKTR_INTEGRITY);return c->status; }
            progress(c,phase,index+1,count);
        }
    }
    if (poll(c)) return c->status;
    c->verified=1;return MNG_BKTR_OK;
}
enum mng_bktr_status mng_bktr_romfs_range(struct mng_bktr *c,uint64_t *offset,uint64_t *size) {
    if (!c || !offset || !size) return MNG_BKTR_INVALID;
    if (poll(c)) return c->status;
    if (!c->verified) return MNG_BKTR_INTEGRITY;
    *offset=c->levels[5].offset;*size=c->levels[5].size;return MNG_BKTR_OK;
}
const char *mng_bktr_status_name(enum mng_bktr_status status) {
    static const char *names[]={"ok","invalid","io","unsupported","limit","nomem","cancelled","integrity"};
    return status>=MNG_BKTR_OK && status<=MNG_BKTR_INTEGRITY ? names[status]:"unknown";
}
