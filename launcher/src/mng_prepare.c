#define _POSIX_C_SOURCE 200809L
#define _FILE_OFFSET_BITS 64
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE
#endif
#include "mng_prepare.h"
#include "mng_container.h"
#include "mng_crypto.h"
#include "mng_content.h"
#include "mng_bktr.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Deliberate supported-subformat quotas, not claims about title compatibility.
 * Payloads are never allocated in full. Even a 16 MiB hash block uses 64 KiB.
 * Caller must discard all sink staging unless the final result is OK. */
#define CHUNK 65536u
#define MAX_SOURCE (UINT64_C(128)*1024*1024*1024)
#define MAX_ASSETS (UINT64_C(64)*1024*1024*1024)
#define MAX_EXEFS (UINT64_C(512)*1024*1024)
#define MAX_HASHES (UINT64_C(64)*1024*1024)
#define MAX_TICKETS 128u
struct ticket { unsigned char rights[16], encrypted[16]; };
struct prep {
    int fd;
    uint64_t size, nca_offset, nca_size;
    const struct mng_key_provider *keys;
    const struct mng_asset_sink *sink;
    const char *hash_phase;
    enum mng_prepare_status failure;
    unsigned char header_key[32], key[16], header[0xc00];
    struct mng_prepare_result result;
};
struct section { struct prep *p; uint64_t start, size; const unsigned char *fs; };
struct level { uint64_t offset, size; unsigned power; };
static int nca_read(void *,uint64_t,void *,size_t);
static uint32_t u32(const unsigned char *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static uint64_t u64(const unsigned char *p) { return u32(p)|(uint64_t)u32(p+4)<<32; }
static int fits(uint64_t a,uint64_t n,uint64_t bound) { return a<=bound && n<=bound-a; }
static int overlap(uint64_t a,uint64_t n,uint64_t b,uint64_t m) {
    return n && m && a<b+m && b<a+n; /* callers checked both bounded sums */
}
static int fail(struct prep *p,enum mng_prepare_status code) { p->failure=code; return -1; }
static int cancelled(struct prep *p) {
    return p->sink->cancelled && p->sink->cancelled(p->sink->context)
        ? fail(p,MNG_PREPARE_CANCELLED):0;
}
static void progress(struct prep *p,const char *phase,uint64_t done,uint64_t total) {
    if (p->sink->progress) p->sink->progress(p->sink->context,phase,done,total);
}
static int source_read(void *context,uint64_t at,void *out,size_t length) {
    struct prep *p=context;
    if (cancelled(p)) return -1;
    if (!fits(at,length,p->size)) return fail(p,MNG_PREPARE_INVALID);
    unsigned char *cursor=out;
    while (length) {
        size_t request=length>CHUNK ? CHUNK:length;
        ssize_t n=pread(p->fd,cursor,request,(off_t)at);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) return fail(p,MNG_PREPARE_IO);
        cursor+=(size_t)n; at+=(uint64_t)n; length-=(size_t)n;
        if (cancelled(p)) return -1;
    }
    return 0;
}
static int sha(const void *bytes,size_t size,unsigned char digest[32]) {
    struct mng_sha256 *state=NULL;
    int result=mng_sha256_init(&state);
    if (!result) result=mng_sha256_update(state,bytes,size);
    if (!result) result=mng_sha256_final(state,digest);
    mng_sha256_free(state); return result;
}
static int section_read(void *context,uint64_t at,void *out,size_t length) {
    struct section *s=context; struct prep *p=s->p;
    if (!fits(at,length,s->size)) return fail(p,MNG_PREPARE_INVALID);
    unsigned char *cursor=out, encrypted[CHUNK], counter[16]={0};
    for (unsigned i=0;i<8;i++) counter[i]=s->fs[0x147-i];
    uint64_t absolute=s->start+at;
    while (length) {
        size_t n=length>CHUNK ? CHUNK:length;
        if (source_read(p,p->nca_offset+absolute,encrypted,n)) return -1;
        if (mng_aes128_ctr(p->key,counter,absolute,encrypted,cursor,n))
            return fail(p,MNG_PREPARE_KEY);
        cursor+=n; absolute+=n; length-=n;
    }
    mng_secure_clear(encrypted,sizeof(encrypted)); return 0;
}
/* Hash a source or decrypted range. IVFC padding is authenticated as zeros;
 * ExeFS blocks are hashed at their actual last-block length without padding. */
static int hash_range(struct prep *p,mng_read_at read,void *reader,uint64_t at,
    uint64_t size,uint64_t padded,unsigned char digest[32]) {
    struct mng_sha256 *state=NULL;
    unsigned char bytes[CHUNK]; uint64_t done=0;
    if (mng_sha256_init(&state)) return fail(p,MNG_PREPARE_NOMEM);
    int result=-1;
    while (done<size) {
        size_t n=size-done>CHUNK ? CHUNK:(size_t)(size-done);
        if (read(reader,at+done,bytes,n)) goto end;
        if (mng_sha256_update(state,bytes,n)) { fail(p,MNG_PREPARE_INTEGRITY); goto end; }
        done+=n;
        if (read==source_read) progress(p,p->hash_phase ? p->hash_phase:"hash-source",done,size);
        else if (read==nca_read) progress(p,"hash-content-nca",done,size);
    }
    memset(bytes,0,sizeof(bytes));
    while (done<padded) {
        size_t n=padded-done>CHUNK ? CHUNK:(size_t)(padded-done);
        if (cancelled(p)) goto end;
        if (mng_sha256_update(state,bytes,n)) { fail(p,MNG_PREPARE_INTEGRITY); goto end; }
        done+=n;
    }
    if (mng_sha256_final(state,digest)) { fail(p,MNG_PREPARE_INTEGRITY); goto end; }
    result=0;
end:
    mng_secure_clear(bytes,sizeof(bytes)); mng_sha256_free(state); return result;
}
static enum mng_prepare_status mapped(enum mng_status status) {
    switch (status) {
        case MNG_OK:return MNG_PREPARE_OK;
        case MNG_LIMIT:return MNG_PREPARE_LIMIT;
        case MNG_NOMEM:return MNG_PREPARE_NOMEM;
        case MNG_IO:return MNG_PREPARE_IO;
        default:return MNG_PREPARE_INVALID;
    }
}
static int container_status(struct prep *p,enum mng_status status) {
    if (status==MNG_OK) return 0;
    if (p->failure==MNG_PREPARE_OK) p->failure=mapped(status);
    return -1;
}
static int suffix(const char *name,const char *ending) {
    size_t n=strlen(name), m=strlen(ending);
    if (n<m) return 0;
    for (size_t i=0;i<m;i++) {
        unsigned char c=(unsigned char)name[n-m+i];
        if (c>='A' && c<='Z') c=(unsigned char)(c+('a'-'A'));
        if (c!=(unsigned char)ending[i]) return 0;
    }
    return 1;
}
static int key_lookup(struct prep *p,const char *name,unsigned char *out,size_t length) {
    return p->keys->lookup(p->keys->context,name,out,length) ? fail(p,MNG_PREPARE_KEY):0;
}
static int tickets_read(struct prep *p,const struct mng_inventory *inventory,
    struct ticket *tickets,size_t *count) {
    *count=0;
    for (size_t i=0;i<inventory->count;i++) {
        const struct mng_entry *entry=inventory->entries+i;
        if (!suffix(entry->name,".tik")) continue;
        unsigned char raw[0x180], signature[4]; uint64_t body;
        if (entry->size<4) return fail(p,MNG_PREPARE_INVALID);
        if (source_read(p,entry->offset,signature,4)) return -1;
        switch (u32(signature)) {
            case 0x10000:case 0x10003:body=0x240;break;
            case 0x10001:case 0x10004:body=0x140;break;
            case 0x10002:case 0x10005:body=0x80;break;
            default:return fail(p,MNG_PREPARE_UNSUPPORTED);
        }
        if (!fits(body,sizeof(raw),entry->size)) return fail(p,MNG_PREPARE_INVALID);
        if (source_read(p,entry->offset+body,raw,sizeof(raw))) return -1;
        if (raw[0x141]) return fail(p,MNG_PREPARE_UNSUPPORTED);
        size_t match=0;
        for (;match<*count;match++) if (!memcmp(tickets[match].rights,raw+0x160,16)) break;
        if (match<*count) {
            if (memcmp(tickets[match].encrypted,raw+0x40,16)) return fail(p,MNG_PREPARE_INVALID);
        } else {
            if (*count==MAX_TICKETS) return fail(p,MNG_PREPARE_LIMIT);
            memcpy(tickets[*count].rights,raw+0x160,16);
            memcpy(tickets[*count].encrypted,raw+0x40,16); (*count)++;
        }
        mng_secure_clear(raw,sizeof(raw));
    }
    return 0;
}
static int header_read(struct prep *p,const struct mng_entry *entry,unsigned char out[0xc00]) {
    unsigned char encrypted[0xc00];
    if (entry->size<sizeof(encrypted)) return fail(p,MNG_PREPARE_INVALID);
    if (source_read(p,entry->offset,encrypted,sizeof(encrypted))) return -1;
    if (mng_aes128_xts_decrypt(p->header_key,0,encrypted,out,sizeof(encrypted)))
        return fail(p,MNG_PREPARE_KEY);
    mng_secure_clear(encrypted,sizeof(encrypted));
    if (memcmp(out+0x200,"NCA3",4)) return fail(p,MNG_PREPARE_KEY);
    if (u64(out+0x208)!=entry->size) return fail(p,MNG_PREPARE_INVALID);
    for (unsigned i=0;i<4;i++) {
        uint64_t a=(uint64_t)u32(out+0x240+i*16)*512;
        uint64_t b=(uint64_t)u32(out+0x244+i*16)*512;
        if (!a && !b) continue;
        if (a<0xc00 || a>=b || b>entry->size) return fail(p,MNG_PREPARE_INVALID);
        for (unsigned j=0;j<i;j++) {
            uint64_t c=(uint64_t)u32(out+0x240+j*16)*512;
            uint64_t d=(uint64_t)u32(out+0x244+j*16)*512;
            if (overlap(a,b-a,c,d-c)) return fail(p,MNG_PREPARE_INVALID);
        }
        unsigned char digest[32];
        if (sha(out+0x400+i*512,512,digest)) return fail(p,MNG_PREPARE_INTEGRITY);
        if (memcmp(digest,out+0x280+i*32,32)) return fail(p,MNG_PREPARE_INTEGRITY);
    }
    return 0;
}
static int choose_legacy_program(struct prep *p,const struct mng_inventory *inventory) {
    unsigned char header[0xc00]; uint64_t common_title=0; unsigned programs=0, ncas=0;
    for (size_t i=0;i<inventory->count;i++) {
        const struct mng_entry *entry=inventory->entries+i;
        if (!suffix(entry->name,".nca")) continue;
        if (++ncas>256) return fail(p,MNG_PREPARE_LIMIT);
        if (header_read(p,entry,header)) return -1;
        uint64_t title=u64(header+0x210);
        if (!title || (common_title && title!=common_title)) return fail(p,MNG_PREPARE_UNSUPPORTED);
        common_title=title;
        if (header[0x205]!=0) continue;
        if (++programs!=1) return fail(p,MNG_PREPARE_UNSUPPORTED);
        for (unsigned j=0;j<4;j++) if (u32(header+0x240+j*16) && header[0x404+j*512]==4)
            return fail(p,MNG_PREPARE_UNSUPPORTED); /* BKTR has a distinct merge contract. */
        memcpy(p->header,header,sizeof(header));
        p->nca_offset=entry->offset; p->nca_size=entry->size; p->result.title_id=title;
        p->result.application_id=title; /* No CNMT: version remains unidentified. */
    }
    mng_secure_clear(header,sizeof(header));
    return programs==1 ? 0:fail(p,MNG_PREPARE_UNSUPPORTED);
}
static int content_key(struct prep *p,const struct ticket *tickets,size_t count) {
    unsigned generation=p->header[0x206]>p->header[0x220] ? p->header[0x206]:p->header[0x220];
    if (generation) generation--;
    unsigned char zero[16]={0}, wrapping[16]; char name[64];
    const unsigned char *rights=p->header+0x230;
    int result=-1;
    if (memcmp(rights,zero,16)) {
        size_t i=0;
        for (;i<count;i++) if (!memcmp(rights,tickets[i].rights,16)) break;
        if (i==count) return fail(p,MNG_PREPARE_KEY);
        snprintf(name,sizeof(name),"titlekek_%02x",generation);
        if (key_lookup(p,name,wrapping,16)) goto done;
        if (mng_aes128_ecb_decrypt(wrapping,tickets[i].encrypted,p->key)) { fail(p,MNG_PREPARE_KEY); goto done; }
    } else {
        static const char *areas[]={"application","ocean","system"};
        unsigned area=p->header[0x207];
        if (area>=3) return fail(p,MNG_PREPARE_UNSUPPORTED);
        snprintf(name,sizeof(name),"key_area_key_%s_%02x",areas[area],generation);
        if (key_lookup(p,name,wrapping,16)) goto done;
        if (mng_aes128_ecb_decrypt(wrapping,p->header+0x320,p->key)) { fail(p,MNG_PREPARE_KEY); goto done; }
    }
    result=0;
done:
    mng_secure_clear(wrapping,sizeof(wrapping)); return result;
}
static int emit_reader(struct prep *p,mng_read_at read,void *reader,uint64_t offset,uint64_t size,const char *path) {
    struct mng_sha256 *hash=NULL;
    unsigned char bytes[CHUNK], digest[32]; int result=-1;
    if (p->result.asset_count>=128 || size>MAX_ASSETS-p->result.asset_bytes)
        return fail(p,MNG_PREPARE_LIMIT);
    if (cancelled(p)) return -1;
    if (mng_sha256_init(&hash)) return fail(p,MNG_PREPARE_NOMEM);
    if (p->sink->begin(p->sink->context,path,size)) { fail(p,MNG_PREPARE_IO); goto done; }
    for (uint64_t at=0;at<size;) {
        size_t n=size-at>CHUNK ? CHUNK:(size_t)(size-at);
        if (read(reader,offset+at,bytes,n)) goto done;
        if (mng_sha256_update(hash,bytes,n)) { fail(p,MNG_PREPARE_INTEGRITY); goto done; }
        if (p->sink->write(p->sink->context,bytes,n)) { fail(p,MNG_PREPARE_IO); goto done; }
        at+=n; progress(p,"write-private-asset",at,size);
    }
    if (cancelled(p)) goto done;
    if (mng_sha256_final(hash,digest)) { fail(p,MNG_PREPARE_INTEGRITY); goto done; }
    if (p->sink->end(p->sink->context,digest)) { fail(p,MNG_PREPARE_IO); goto done; }
    p->result.asset_count++; p->result.asset_bytes+=size; result=0;
done:
    mng_secure_clear(bytes,sizeof(bytes)); mng_sha256_free(hash); return result;
}
static int emit(struct section *s,uint64_t offset,uint64_t size,const char *path) {
    return emit_reader(s->p,section_read,s,offset,size,path);
}
static int verified_pfs(struct section *s,struct mng_inventory *inventory,const char *phase) {
    struct prep *p=s->p; const unsigned char *fs=s->fs;
    uint32_t block=u32(fs+0x28), levels=u32(fs+0x2c);
    uint64_t hashes=u64(fs+0x30), hash_size=u64(fs+0x38), data=u64(fs+0x40), size=u64(fs+0x48);
    if (size>MAX_EXEFS || hash_size>MAX_HASHES) return fail(p,MNG_PREPARE_LIMIT);
    if (levels!=2 || block<4096 || block>(1u<<24) || (block&(block-1)))
        return fail(p,MNG_PREPARE_UNSUPPORTED);
    uint64_t blocks=size/block+(size%block!=0);
    if (!size || !fits(hashes,hash_size,s->size) || !fits(data,size,s->size) ||
        hash_size<blocks*32 || overlap(hashes,hash_size,data,size)) return fail(p,MNG_PREPARE_INVALID);
    unsigned char digest[32], expected[32];
    if (hash_range(p,section_read,s,hashes,hash_size,hash_size,digest)) return -1;
    if (memcmp(digest,fs+8,32)) return fail(p,MNG_PREPARE_INTEGRITY);
    for (uint64_t i=0;i<blocks;i++) {
        uint64_t n=size-i*block; if (n>block) n=block;
        if (section_read(s,hashes+i*32,expected,32) ||
            hash_range(p,section_read,s,data+i*block,n,n,digest)) return -1;
        if (memcmp(digest,expected,32)) return fail(p,MNG_PREPARE_INTEGRITY);
        progress(p,phase,i+1,blocks);
    }
    return container_status(p,mng_partition_inspect(section_read,s,s->size,data,size,MNG_PFS0,inventory));
}
static int exefs(struct section *s) {
    struct prep *p=s->p;
    struct mng_inventory inventory={0};
    if (verified_pfs(s,&inventory,"verify-exefs")) return -1;
    int found=0, main_found=0, result=-1;
    if (inventory.count>127) { fail(p,MNG_PREPARE_LIMIT); goto done; }
    for (size_t i=0;i<inventory.count;i++) {
        const char *name=inventory.entries[i].name;
        size_t length=strlen(name);
        if (length>64) { fail(p,MNG_PREPARE_UNSUPPORTED); goto done; }
        for (size_t j=0;j<length;j++) {
            unsigned char c=(unsigned char)name[j];
            if (!((c>='a' && c<='z') || (c>='A' && c<='Z') ||
                  (c>='0' && c<='9') || c=='.' || c=='_' || c=='-')) {
                fail(p,MNG_PREPARE_UNSUPPORTED); goto done;
            }
        }
        for (size_t j=0;j<i;j++) {
            const char *other=inventory.entries[j].name; size_t k=0;
            for (;name[k] && other[k];k++) {
                unsigned char a=(unsigned char)name[k], b=(unsigned char)other[k];
                if (a>='A' && a<='Z') a=(unsigned char)(a+32);
                if (b>='A' && b<='Z') b=(unsigned char)(b+32);
                if (a!=b) break;
            }
            if (!name[k] && !other[k]) { fail(p,MNG_PREPARE_INVALID); goto done; }
        }
        if (!strcmp(name,"main.npdm")) found=1;
        if (!strcmp(name,"main")) main_found=1;
    }
    if (!found || !main_found) { fail(p,MNG_PREPARE_UNSUPPORTED); goto done; }
    for (size_t i=0;i<inventory.count;i++) {
        const struct mng_entry *e=inventory.entries+i;
        char path[MNG_MAX_NAME+8];
        snprintf(path,sizeof(path),"exefs/%s",e->name);
        if (emit(s,e->offset,e->size,path)) goto done;
    }
    p->result.exefs_verified=1; result=0;
done:
    mng_inventory_free(&inventory); return result;
}
struct observed_nca {
    const struct mng_entry *entry;
    struct mng_content_candidate candidate;
    uint64_t title_id;
    struct prep *owner;
};
struct catalog {
    struct observed_nca *observed;
    struct mng_content_candidate *candidates;
    struct mng_content *metadata[64];
    size_t nca_count,meta_count,metadata_bytes;
    int has_meta;
};
static int content_status(struct prep *p,enum mng_content_status status) {
    if (status==MNG_CONTENT_OK) return 0;
    switch (status) {
        case MNG_CONTENT_LIMIT:return fail(p,MNG_PREPARE_LIMIT);
        case MNG_CONTENT_NOMEM:return fail(p,MNG_PREPARE_NOMEM);
        case MNG_CONTENT_INTEGRITY:case MNG_CONTENT_MISSING:case MNG_CONTENT_MISMATCH:
            return fail(p,MNG_PREPARE_INTEGRITY);
        case MNG_CONTENT_UNSUPPORTED:case MNG_CONTENT_DEPENDENCY:
            return fail(p,MNG_PREPARE_UNSUPPORTED);
        default:return fail(p,MNG_PREPARE_INVALID);
    }
}
static int nca_read(void *context,uint64_t at,void *out,size_t size) {
    return source_read(context,at,out,size);
}
static int read_metadata(struct prep *p,const struct ticket *tickets,size_t ticket_count,
    struct mng_content **out,size_t *metadata_bytes) {
    if (content_key(p,tickets,ticket_count)) return -1;
    struct section section={0};
    for (unsigned i=0;i<4;i++) {
        uint64_t start=(uint64_t)u32(p->header+0x240+i*16)*512;
        if (!start) continue;
        const unsigned char *fs=p->header+0x400+i*512;
        if (section.p || fs[2]!=1 || fs[3]!=2 || fs[4]!=3) return fail(p,MNG_PREPARE_UNSUPPORTED);
        if (u64(fs+0x48)>16u*1024u*1024u) return fail(p,MNG_PREPARE_LIMIT);
        section=(struct section){p,start,(uint64_t)u32(p->header+0x244+i*16)*512-start,fs};
    }
    if (!section.p) return fail(p,MNG_PREPARE_UNSUPPORTED);
    struct mng_inventory inventory={0}; unsigned char *bytes=NULL; int result=-1;
    if (verified_pfs(&section,&inventory,"verify-metadata")) return -1;
    if (inventory.count!=1 || !suffix(inventory.entries[0].name,".cnmt")) { fail(p,MNG_PREPARE_UNSUPPORTED);goto done; }
    const struct mng_entry *e=inventory.entries;
    if (e->size>1024u*1024u || e->size>16u*1024u*1024u-*metadata_bytes) { fail(p,MNG_PREPARE_LIMIT);goto done; }
    bytes=malloc(e->size ? (size_t)e->size:1);
    if (!bytes) { fail(p,MNG_PREPARE_NOMEM);goto done; }
    if (section_read(&section,e->offset,bytes,(size_t)e->size) ||
        content_status(p,mng_content_parse(e->name,bytes,(size_t)e->size,out))) goto done;
    if ((*out)->title_id!=u64(p->header+0x210)) {
        mng_content_free(*out);*out=NULL;fail(p,MNG_PREPARE_INTEGRITY);goto done;
    }
    *metadata_bytes+=(size_t)e->size;result=0;
done:
    if (bytes) { mng_secure_clear(bytes,inventory.entries[0].size);free(bytes); }
    mng_inventory_free(&inventory);return result;
}
static void catalog_free(struct catalog *c) {
    for (size_t i=0;i<c->meta_count;i++) mng_content_free(c->metadata[i]);
    free(c->observed);free(c->candidates);memset(c,0,sizeof(*c));
}
static int catalog_read(struct prep *p,const struct mng_inventory *inventory,
    const struct ticket *tickets,size_t ticket_count,struct catalog *c) {
    c->observed=calloc(256,sizeof(*c->observed));
    c->candidates=calloc(256,sizeof(*c->candidates));
    if (!c->observed || !c->candidates) return fail(p,MNG_PREPARE_NOMEM);
    /* Inventory all headers first. A present Meta NCA always enters verified
     * metadata handling; malformed metadata can never trigger legacy fallback. */
    for (size_t i=0;i<inventory->count;i++) {
        const struct mng_entry *e=inventory->entries+i;
        if (!suffix(e->name,".nca")) continue;
        if (c->nca_count==256) return fail(p,MNG_PREPARE_LIMIT);
        if (header_read(p,e,p->header)) return -1;
        struct observed_nca *observed=c->observed+c->nca_count++;
        observed->entry=e;observed->owner=p;
        observed->candidate.nca_type=p->header[0x205];
        observed->title_id=u64(p->header+0x210);
        if (p->header[0x205]==1) c->has_meta=1;
    }
    if (!c->has_meta) return 0;
    for (size_t i=0;i<c->nca_count;i++) {
        const struct mng_entry *e=c->observed[i].entry;
        struct mng_content_candidate *candidate=&c->observed[i].candidate;
        candidate->size=e->size;
        progress(p,"hash-content-nca",0,e->size);
        if (hash_range(p,nca_read,p,e->offset,e->size,e->size,candidate->sha256)) return -1;
        progress(p,"hash-content-nca",e->size,e->size);
        memcpy(candidate->id,candidate->sha256,16);c->candidates[i]=*candidate;
        if (candidate->nca_type!=1) continue;
        if (c->meta_count==64) return fail(p,MNG_PREPARE_LIMIT);
        if (header_read(p,e,p->header)) return -1;
        p->nca_offset=e->offset;p->nca_size=e->size;
        if (read_metadata(p,tickets,ticket_count,c->metadata+c->meta_count,&c->metadata_bytes)) return -1;
        c->meta_count++;
    }
    return 0;
}
static int bind_metadata(struct prep *p,struct mng_content *const *metadata,size_t meta_count,
    const struct observed_nca *observed,const struct mng_content_candidate *candidates,size_t nca_count) {
    for (size_t i=0;i<meta_count;i++) {
        const struct mng_content *owner=metadata[i];
        if (content_status(p,mng_content_bind(owner,candidates,nca_count))) return -1;
        for (size_t j=0;j<owner->content_count;j++) {
            const struct mng_content_record *record=owner->contents+j;
            /* Bounded single-program mapping: indexed subprograms and nested
             * Meta-content relationships need distinct grounded policies.
             * Base and patch Program/Control keep the application ID (see
             * extract_exefs.py and extract_app_icon.py); AddOn Data uses its
             * declared add-on title. Never infer this identity from a name. */
            if (record->id_offset || record->role==0 ||
                (owner->type==MNG_CONTENT_ADDON && record->role!=2)) {
                return fail(p,MNG_PREPARE_UNSUPPORTED);
            }
            uint64_t expected=owner->type==MNG_CONTENT_ADDON ? owner->title_id:owner->application_id;
            size_t k=0;
            while (k<nca_count && memcmp(record->id,observed[k].candidate.id,16)) k++;
            if (k==nca_count || observed[k].title_id!=expected) {
                return fail(p,MNG_PREPARE_INTEGRITY);
            }
        }
    }
    return 0;
}
static int all_declared(struct prep *p,struct mng_content *const *metadata,size_t meta_count,
    const struct mng_content_candidate *candidates,size_t nca_count) {
    /* Every non-Meta NCA must be declared by one of the verified CNMTs, including
     * bundled updates/DLC. Their metadata is checked; their payload is not
     * silently composed or represented as prepared by this base-only result. */
    for (size_t i=0;i<nca_count;i++) {
        if (candidates[i].nca_type==1) continue;
        int found=0;
        for (size_t j=0;j<meta_count;j++) for (size_t k=0;k<metadata[j]->content_count;k++)
            if (!memcmp(candidates[i].id,metadata[j]->contents[k].id,16)) found=1;
        if (!found) return fail(p,MNG_PREPARE_INTEGRITY);
    }
    return 0;
}
static const struct observed_nca *program_observation(struct prep *p,const struct mng_content *base,
    const struct observed_nca *observed,size_t nca_count) {
    const struct mng_content_record *program=NULL;
    for (size_t i=0;i<base->content_count;i++) if (base->contents[i].role==1) {
        if (program || base->contents[i].id_offset) { fail(p,MNG_PREPARE_UNSUPPORTED);return NULL; }
        program=base->contents+i;
    }
    if (!program) { fail(p,MNG_PREPARE_UNSUPPORTED);return NULL; }
    size_t selected=0;
    while (selected<nca_count && memcmp(program->id,observed[selected].candidate.id,16)) selected++;
    if (selected==nca_count) { fail(p,MNG_PREPARE_INTEGRITY);return NULL; }
    return observed+selected;
}
static int choose_program(struct prep *p,const struct mng_inventory *inventory,
    const struct ticket *tickets,size_t ticket_count) {
    struct catalog c={0};int result=-1;
    if (catalog_read(p,inventory,tickets,ticket_count,&c)) goto done;
    if (!c.has_meta) { result=choose_legacy_program(p,inventory);goto done; }
    uint64_t application=0;
    for (size_t i=0;i<c.meta_count;i++) if (c.metadata[i]->type==MNG_CONTENT_APPLICATION) {
        application=c.metadata[i]->application_id;break;
    }
    if (!application) { fail(p,MNG_PREPARE_UNSUPPORTED);goto done; }
    if (bind_metadata(p,c.metadata,c.meta_count,c.observed,c.candidates,c.nca_count)) goto done;
    struct mng_content_plan plan={0};
    if (content_status(p,mng_content_plan((const struct mng_content *const *)c.metadata,c.meta_count,
                                        c.candidates,c.nca_count,application,UINT32_MAX,&plan))) goto done;
    const struct mng_content *base=c.metadata[plan.base_index];
    if (base->required_application_version>base->version) { fail(p,MNG_PREPARE_UNSUPPORTED);goto done; }
    if (all_declared(p,c.metadata,c.meta_count,c.candidates,c.nca_count)) goto done;
    const struct observed_nca *selected=program_observation(p,base,c.observed,c.nca_count);
    if (!selected) goto done;
    const struct mng_entry *entry=selected->entry;
    if (header_read(p,entry,p->header)) goto done;
    if (u64(p->header+0x210)!=base->title_id) { fail(p,MNG_PREPARE_INTEGRITY);goto done; }
    for (unsigned i=0;i<4;i++) if (u32(p->header+0x240+i*16) && p->header[0x404+i*512]==4) {
        fail(p,MNG_PREPARE_UNSUPPORTED);goto done;
    }
    p->nca_offset=entry->offset;p->nca_size=entry->size;
    p->result.title_id=base->title_id;p->result.application_id=application;
    p->result.title_version=base->version;p->result.version_identified=1;p->result.content_role=base->type;
    result=0;
done:
    catalog_free(&c);return result;
}
static int verify_romfs(struct section *s,uint64_t *image_offset,uint64_t *image_size) {
    struct prep *p=s->p; const unsigned char *fs=s->fs;
    if (memcmp(fs+8,"IVFC",4) || u32(fs+12)!=0x20000 || u32(fs+16)!=32 || u32(fs+20)!=7)
        return fail(p,MNG_PREPARE_UNSUPPORTED);
    struct level levels[6];
    for (unsigned i=0;i<6;i++) {
        const unsigned char *raw=fs+0x18+i*24;
        levels[i]=(struct level){u64(raw),u64(raw+8),u32(raw+16)};
        if (levels[i].power<12 || levels[i].power>24 || u32(raw+20)) return fail(p,MNG_PREPARE_UNSUPPORTED);
        if (!levels[i].size || !fits(levels[i].offset,levels[i].size,s->size)) return fail(p,MNG_PREPARE_INVALID);
        if (levels[i].size>(i==5 ? MAX_ASSETS:MAX_HASHES)) return fail(p,MNG_PREPARE_LIMIT);
        for (unsigned j=0;j<i;j++) if (overlap(levels[i].offset,levels[i].size,levels[j].offset,levels[j].size))
            return fail(p,MNG_PREPARE_INVALID);
    }
    for (unsigned i=0;i<6;i++) {
        uint64_t block=UINT64_C(1)<<levels[i].power;
        uint64_t count=levels[i].size/block+(levels[i].size%block!=0);
        uint64_t parent_size=i ? levels[i-1].size:32;
        if (count>parent_size/32) return fail(p,MNG_PREPARE_INVALID);
        for (uint64_t index=0;index<count;index++) {
            unsigned char digest[32], expected[32];
            uint64_t n=levels[i].size-index*block; if (n>block) n=block;
            if (i) { if (section_read(s,levels[i-1].offset+index*32,expected,32)) return -1; }
            else memcpy(expected,fs+0xc8,32);
            if (hash_range(p,section_read,s,levels[i].offset+index*block,n,block,digest)) return -1;
            if (memcmp(digest,expected,32)) return fail(p,MNG_PREPARE_INTEGRITY);
            progress(p,"verify-ivfc",index+1,count);
        }
    }
    *image_offset=levels[5].offset;*image_size=levels[5].size;return 0;
}
static int romfs(struct section *s) {
    struct prep *p=s->p;uint64_t offset,size;
    if (verify_romfs(s,&offset,&size) || emit(s,offset,size,"romfs.bin")) return -1;
    p->result.romfs_verified=1; return 0;
}
static int program_sections(struct prep *p,struct section *exe,struct section *rom,int bktr) {
    for (unsigned i=0;i<4;i++) {
        uint64_t start=(uint64_t)u32(p->header+0x240+i*16)*512;
        uint64_t end=(uint64_t)u32(p->header+0x244+i*16)*512;
        if (!start) continue;
        const unsigned char *fs=p->header+0x400+i*512;
        struct section s={p,start,end-start,fs};
        if (fs[2]==1 && fs[3]==2 && fs[4]==3 && !exe->p) *exe=s;
        else if (fs[2]==0 && fs[3]==3 && fs[4]==(bktr ? 4:3) && !rom->p) *rom=s;
        else return fail(p,MNG_PREPARE_UNSUPPORTED);
    }
    if (!exe->p || !rom->p) return fail(p,MNG_PREPARE_UNSUPPORTED);
    return 0;
}
static int sections(struct prep *p) {
    struct section exe={0},rom={0};
    if (program_sections(p,&exe,&rom,0)) return -1;
    return exefs(&exe) || romfs(&rom) ? -1:0;
}
static int stable(const struct stat *a,const struct stat *b) {
#ifdef __APPLE__
    const struct timespec am=a->st_mtimespec, bm=b->st_mtimespec;
    const struct timespec ac=a->st_ctimespec, bc=b->st_ctimespec;
#else
    const struct timespec am=a->st_mtim, bm=b->st_mtim;
    const struct timespec ac=a->st_ctim, bc=b->st_ctim;
#endif
    return S_ISREG(b->st_mode) && a->st_dev==b->st_dev && a->st_ino==b->st_ino &&
        a->st_size==b->st_size && am.tv_sec==bm.tv_sec && am.tv_nsec==bm.tv_nsec &&
        ac.tv_sec==bc.tv_sec && ac.tv_nsec==bc.tv_nsec;
}
static int arguments_valid(const struct mng_key_provider *keys,const struct mng_asset_sink *sink,
    const struct mng_prepare_result *result) {
    if (!result || !keys || !keys->lookup || !sink || !sink->begin || !sink->write || !sink->end)
        return 0;
    unsigned char zero[32]={0};
    if (result->title_id || result->source_size || result->asset_count || result->asset_bytes ||
        result->exefs_verified || result->romfs_verified || result->application_id || result->title_version ||
        result->version_identified || result->content_role || result->update_applied || result->update_source_size ||
        result->patch_title_id || result->base_title_version || memcmp(result->source_sha256,zero,32) ||
        memcmp(result->update_source_sha256,zero,32))
        return 0;
    return 1;
}
enum mng_prepare_status mng_prepare_fd(int fd,const struct mng_key_provider *keys,
    const struct mng_asset_sink *sink,struct mng_prepare_result *result) {
    if (!arguments_valid(keys,sink,result)) return MNG_PREPARE_INVALID;
    struct stat before, after;
    if (fstat(fd,&before)) return MNG_PREPARE_IO;
    if (!S_ISREG(before.st_mode) || before.st_size<0) return MNG_PREPARE_INVALID;
    if ((uint64_t)before.st_size>MAX_SOURCE) return MNG_PREPARE_LIMIT;
    struct prep p={0}; p.fd=fd; p.size=(uint64_t)before.st_size; p.keys=keys; p.sink=sink;
    struct mng_inventory inventory={0};
    struct ticket tickets[MAX_TICKETS]; size_t count=0;
    if (cancelled(&p)) goto done;
    if (container_status(&p,mng_container_inspect(source_read,&p,p.size,&inventory))) goto done;
    if (key_lookup(&p,"header_key",p.header_key,32) || tickets_read(&p,&inventory,tickets,&count) ||
        choose_program(&p,&inventory,tickets,count) || content_key(&p,tickets,count) || sections(&p)) goto done;
    progress(&p,"hash-source",0,p.size);
    if (hash_range(&p,source_read,&p,0,p.size,p.size,p.result.source_sha256)) goto done;
    progress(&p,"hash-source",p.size,p.size);
    if (cancelled(&p)) goto done;
    p.result.source_size=p.size;
done:
    if (fstat(fd,&after) || !stable(&before,&after)) p.failure=MNG_PREPARE_IO;
    enum mng_prepare_status status=p.failure;
    if (status==MNG_PREPARE_OK) *result=p.result;
    mng_inventory_free(&inventory);
    mng_secure_clear(tickets,sizeof(tickets)); mng_secure_clear(&p,sizeof(p));
    return status;
}
struct paired_sources {
    struct prep *base,*update;
    struct stat base_before,update_before;
    struct mng_bktr *reader;
};
static int paired_stopped(void *opaque) {
    struct paired_sources *sources=opaque;
    return cancelled(sources->update)!=0;
}
static int paired_changed(void *opaque) {
    struct paired_sources *sources=opaque;struct stat base,update;
    return fstat(sources->base->fd,&base) || fstat(sources->update->fd,&update) ||
        !stable(&sources->base_before,&base) || !stable(&sources->update_before,&update);
}
static void paired_progress(void *opaque,const char *phase,uint64_t done,uint64_t total) {
    progress(((struct paired_sources *)opaque)->update,phase,done,total);
}
static int bktr_status(struct prep *p,enum mng_bktr_status status) {
    switch (status) {
        case MNG_BKTR_OK:return 0;
        case MNG_BKTR_CANCELLED:return fail(p,MNG_PREPARE_CANCELLED);
        case MNG_BKTR_IO:return fail(p,MNG_PREPARE_IO);
        case MNG_BKTR_UNSUPPORTED:return fail(p,MNG_PREPARE_UNSUPPORTED);
        case MNG_BKTR_LIMIT:return fail(p,MNG_PREPARE_LIMIT);
        case MNG_BKTR_NOMEM:return fail(p,MNG_PREPARE_NOMEM);
        case MNG_BKTR_INTEGRITY:return fail(p,MNG_PREPARE_INTEGRITY);
        default:return fail(p,MNG_PREPARE_INVALID);
    }
}
static int patch_nca_read(void *opaque,uint64_t offset,void *bytes,size_t size) {
    struct prep *p=opaque;
    if (!fits(offset,size,p->nca_size)) return fail(p,MNG_PREPARE_INVALID);
    return source_read(p,p->nca_offset+offset,bytes,size);
}
static int composed_read(void *opaque,uint64_t offset,void *bytes,size_t size) {
    struct paired_sources *sources=opaque;
    if (!mng_bktr_read_at(sources->reader,offset,bytes,size)) return 0;
    return bktr_status(sources->update,mng_bktr_status(sources->reader));
}
static enum mng_prepare_status prepare_update(int base_fd,int update_fd,
    const struct mng_key_provider *keys,const struct mng_asset_sink *sink,
    uint32_t target_version,int exact,struct mng_prepare_result *result) {
    if (!arguments_valid(keys,sink,result)) return MNG_PREPARE_INVALID;
    struct stat base_before,update_before;
    if (fstat(base_fd,&base_before) || fstat(update_fd,&update_before)) return MNG_PREPARE_IO;
    if (!S_ISREG(base_before.st_mode) || !S_ISREG(update_before.st_mode) || base_before.st_size<0 || update_before.st_size<0 ||
        (base_before.st_dev==update_before.st_dev && base_before.st_ino==update_before.st_ino)) return MNG_PREPARE_INVALID;
    if ((uint64_t)base_before.st_size>MAX_SOURCE || (uint64_t)update_before.st_size>MAX_SOURCE) return MNG_PREPARE_LIMIT;
    struct prep base={0},update={0};
    base.fd=base_fd;base.size=(uint64_t)base_before.st_size;base.keys=keys;base.sink=sink;base.hash_phase="hash-base-source";
    update.fd=update_fd;update.size=(uint64_t)update_before.st_size;update.keys=keys;update.sink=sink;update.hash_phase="hash-update-source";
    struct paired_sources sources={&base,&update,base_before,update_before,NULL};
    struct mng_inventory inventories[2]={{0},{0}};
    struct ticket tickets[2][MAX_TICKETS];size_t ticket_counts[2]={0,0};
    struct catalog catalogs[2]={{0},{0}};
    struct observed_nca *observed=calloc(512,sizeof(*observed));
    struct mng_content_candidate *candidates=calloc(512,sizeof(*candidates));
    struct mng_content *metadata[128];size_t nca_count=0,meta_count=0;
    struct prep *inputs[2]={&base,&update};int success=0;
    if (!observed || !candidates) { fail(&update,MNG_PREPARE_NOMEM);goto done; }
    for (unsigned input=0;input<2;input++) {
        struct prep *p=inputs[input];struct catalog *c=catalogs+input;
        if (cancelled(p) || container_status(p,mng_container_inspect(source_read,p,p->size,inventories+input)) ||
            key_lookup(p,"header_key",p->header_key,32) || tickets_read(p,inventories+input,tickets[input],ticket_counts+input) ||
            catalog_read(p,inventories+input,tickets[input],ticket_counts[input],c)) goto done;
        if (!c->has_meta) { fail(&update,MNG_PREPARE_UNSUPPORTED);goto done; }
        for (size_t i=0;i<c->meta_count;i++) metadata[meta_count++]=c->metadata[i];
        for (size_t i=0;i<c->nca_count;i++) {
            const struct observed_nca *record=c->observed+i;
            size_t j=0;while (j<nca_count && memcmp(record->candidate.id,observed[j].candidate.id,16)) j++;
            if (j<nca_count) {
                const struct observed_nca *previous=observed+j;
                if (previous->owner==p) { fail(&update,MNG_PREPARE_INVALID);goto done; }
                if (record->candidate.size!=previous->candidate.size || record->candidate.nca_type!=previous->candidate.nca_type ||
                    record->title_id!=previous->title_id || memcmp(record->candidate.sha256,previous->candidate.sha256,32)) {
                    fail(&update,MNG_PREPARE_INTEGRITY);goto done;
                }
                continue; /* An identical shared content NCA in both inputs. */
            }
            observed[nca_count]=*record;candidates[nca_count++]=record->candidate;
        }
    }
    if (bind_metadata(&update,metadata,meta_count,observed,candidates,nca_count) ||
        all_declared(&update,metadata,meta_count,candidates,nca_count)) goto done;
    uint64_t application=0;
    for (size_t i=0;i<catalogs[0].meta_count;i++) if (catalogs[0].metadata[i]->type==MNG_CONTENT_APPLICATION) {
        application=catalogs[0].metadata[i]->application_id;break;
    }
    int applicable_patch=0;
    for (size_t i=0;i<catalogs[1].meta_count;i++) if (catalogs[1].metadata[i]->type==MNG_CONTENT_PATCH &&
        catalogs[1].metadata[i]->application_id==application && (!exact || catalogs[1].metadata[i]->version==target_version)) applicable_patch=1;
    if (!application || !applicable_patch) { fail(&update,MNG_PREPARE_UNSUPPORTED);goto done; }
    struct mng_content_plan plan={0};
    if (content_status(&update,mng_content_plan((const struct mng_content *const *)metadata,meta_count,candidates,nca_count,
                                               application,exact ? target_version:UINT32_MAX,&plan))) goto done;
    if (plan.base_index>=catalogs[0].meta_count || plan.patch_index==SIZE_MAX || plan.patch_index<catalogs[0].meta_count ||
        (exact && metadata[plan.patch_index]->version!=target_version)) { fail(&update,MNG_PREPARE_UNSUPPORTED);goto done; }
    const struct mng_content *base_meta=metadata[plan.base_index],*patch_meta=metadata[plan.patch_index];
    const struct observed_nca *base_program=program_observation(&update,base_meta,observed,nca_count);
    const struct observed_nca *patch_program=program_observation(&update,patch_meta,observed,nca_count);
    if (!base_program || !patch_program) goto done;
    if (base_program->owner!=&base || patch_program->owner!=&update) { fail(&update,MNG_PREPARE_UNSUPPORTED);goto done; }
    if (header_read(&base,base_program->entry,base.header) || header_read(&update,patch_program->entry,update.header)) goto done;
    base.nca_offset=base_program->entry->offset;base.nca_size=base_program->entry->size;
    update.nca_offset=patch_program->entry->offset;update.nca_size=patch_program->entry->size;
    if (content_key(&base,tickets[0],ticket_counts[0]) || content_key(&update,tickets[1],ticket_counts[1])) goto done;
    struct section base_exe={0},base_rom={0},patch_exe={0},patch_rom={0};
    if (program_sections(&base,&base_exe,&base_rom,0) || program_sections(&update,&patch_exe,&patch_rom,1)) goto done;
    struct mng_inventory base_pfs={0};
    if (verified_pfs(&base_exe,&base_pfs,"verify-base-exefs")) goto done;
    mng_inventory_free(&base_pfs);
    uint64_t original_offset,original_size;
    if (verify_romfs(&base_rom,&original_offset,&original_size)) goto done;
    struct mng_bktr_config config={0};
    config.base=(struct mng_bktr_source){&base_rom,base_rom.size,section_read};
    config.patch_nca=(struct mng_bktr_source){&update,update.nca_size,patch_nca_read};
    config.section_offset=patch_rom.start;config.section_size=patch_rom.size;config.fs_header=patch_rom.fs;
    memcpy(config.key,update.key,16);
    struct mng_bktr_callbacks callbacks={&sources,paired_stopped,paired_changed,paired_progress};
    enum mng_bktr_status opened=mng_bktr_open(&config,&callbacks,&sources.reader);
    mng_secure_clear(config.key,16);
    if (bktr_status(&update,opened) || bktr_status(&update,mng_bktr_verify_ivfc(sources.reader))) goto done;
    uint64_t offset,size;
    if (bktr_status(&update,mng_bktr_romfs_range(sources.reader,&offset,&size))) goto done;
    if (exefs(&patch_exe) || emit_reader(&update,composed_read,&sources,offset,size,"romfs.bin")) goto done;
    update.result.romfs_verified=1;update.result.title_id=application;update.result.application_id=application;
    update.result.title_version=patch_meta->version;update.result.version_identified=1;update.result.content_role=MNG_CONTENT_PATCH;
    update.result.update_applied=1;update.result.base_title_version=base_meta->version;update.result.patch_title_id=patch_meta->title_id;
    update.result.source_size=base.size;update.result.update_source_size=update.size;
    if (hash_range(&base,source_read,&base,0,base.size,base.size,update.result.source_sha256) ||
        hash_range(&update,source_read,&update,0,update.size,update.size,update.result.update_source_sha256) ||
        cancelled(&base) || cancelled(&update)) goto done;
    success=1;
done:;
    int changed=paired_changed(&sources);
    if (changed) success=0;
    enum mng_prepare_status status=changed ? MNG_PREPARE_IO:base.failure ? base.failure:update.failure;
    if (!success && status==MNG_PREPARE_OK) status=MNG_PREPARE_INTEGRITY;
    if (success && status==MNG_PREPARE_OK) *result=update.result;
    mng_bktr_close(sources.reader);
    for (unsigned i=0;i<2;i++) { catalog_free(catalogs+i);mng_inventory_free(inventories+i); }
    free(observed);free(candidates);mng_secure_clear(tickets,sizeof(tickets));
    mng_secure_clear(&base,sizeof(base));mng_secure_clear(&update,sizeof(update));
    return status;
}
enum mng_prepare_status mng_prepare_update_fd(int base_fd,int update_fd,
    const struct mng_key_provider *keys,const struct mng_asset_sink *sink,
    uint32_t target_version,struct mng_prepare_result *result) {
    return prepare_update(base_fd,update_fd,keys,sink,target_version,1,result);
}
enum mng_prepare_status mng_prepare_latest_update_fd(int base_fd,int update_fd,
    const struct mng_key_provider *keys,const struct mng_asset_sink *sink,
    struct mng_prepare_result *result) {
    return prepare_update(base_fd,update_fd,keys,sink,0,0,result);
}
const char *mng_prepare_status_name(enum mng_prepare_status status) {
    static const char *names[]={"ok","invalid","io","unsupported","key","integrity","cancelled","limit","nomem"};
    return status>=MNG_PREPARE_OK && status<=MNG_PREPARE_NOMEM ? names[status]:"unknown";
}
