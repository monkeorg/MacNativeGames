#include "mng_content.h"
#include "mng_crypto.h"
#include <stdlib.h>
#include <string.h>

/* Original implementation from published format facts, not imported code.
 * Layout references (read-only): Atmosphere-NX/Atmosphere commit
 * 6b0c077b4c608a3a2ee712b8dc35fee87ceb62e8, libstratosphere/include/stratosphere/
 * ncm/{ncm_content_meta.hpp,ncm_content_info.hpp,ncm_content_info_data.hpp,
 * ncm_content_meta_type.hpp,ncm_content_type.hpp}. Public packaged CNMT format:
 * header32 + type extended header + content56*n + meta16*n + extended data
 * + SHA25632. No GPL implementation or declaration code is incorporated. */
#define META_LIMIT (1024u*1024u)
#define CONTENT_LIMIT 4096u
#define DEP_LIMIT 256u
#define CATALOG_LIMIT 256u
#define CANDIDATE_LIMIT 16384u
#define NCA_LIMIT (UINT64_C(128)<<30)
static uint16_t u16(const unsigned char *p) { return (uint16_t)(p[0]|(uint16_t)p[1]<<8); }
static uint32_t u32(const unsigned char *p) { return p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24; }
static uint64_t u64(const unsigned char *p) { return u32(p)|(uint64_t)u32(p+4)<<32; }
static int known(unsigned type) { return type==0x80 || type==0x81 || type==0x82; }
static int zero(const unsigned char *p,size_t length) {
    unsigned n=0; for (size_t i=0;i<length;i++) n|=p[i]; return n==0;
}
static int name_matches(const char *name,unsigned type,uint64_t title) {
    const char *prefix=type==0x80 ? "Application_":type==0x81 ? "Patch_":"AddOnContent_";
    size_t n=strlen(prefix);
    if (!name || strlen(name)!=n+16+5 || memcmp(name,prefix,n) || strcmp(name+n+16,".cnmt")) return 0;
    uint64_t parsed=0;
    for (size_t i=0;i<16;i++) {
        unsigned char c=(unsigned char)name[n+i]; unsigned digit;
        if (c>='0' && c<='9') digit=c-'0';
        else if (c>='a' && c<='f') digit=c-'a'+10;
        else if (c>='A' && c<='F') digit=c-'A'+10;
        else return 0;
        parsed=(parsed<<4)|digit;
    }
    return parsed==title;
}
void mng_content_free(struct mng_content *meta) {
    if (meta) { free(meta->contents);free(meta->dependencies);free(meta); }
}
enum mng_content_status mng_content_parse(const char *name,const void *bytes,size_t length,struct mng_content **out) {
    if (!out) return MNG_CONTENT_INVALID;
    *out=NULL;
    if (length>META_LIMIT) return MNG_CONTENT_LIMIT;
    if (!bytes || length<64) return MNG_CONTENT_INVALID;
    const unsigned char *p=bytes;
    unsigned type=p[12], ext=u16(p+14), count=u16(p+16), dependencies=u16(p+18);
    if (!known(type) || p[13] || p[21]>6 || p[22] || p[23] || (p[20]&~7u)) return MNG_CONTENT_UNSUPPORTED;
    if (!u64(p) || !zero(p+28,4) || !name_matches(name,type,u64(p))) return MNG_CONTENT_INVALID;
    if (count>CONTENT_LIMIT || dependencies>DEP_LIMIT) return MNG_CONTENT_LIMIT;
    if (!count) return MNG_CONTENT_INVALID;
    if ((type==0x80 && ext!=16) || (type==0x81 && ext!=24) ||
        (type==0x82 && ext!=16 && ext!=24)) return MNG_CONTENT_UNSUPPORTED;
    if (length<32u+ext+32u) return MNG_CONTENT_INVALID;
    uint32_t extended=type==0x81 ? u32(p+44):0;
    size_t end=32u+ext+(size_t)count*56+(size_t)dependencies*16;
    if (extended>META_LIMIT || end>length || extended>length-end || length-end-extended!=32)
        return MNG_CONTENT_INVALID;
    if (type==0x81 && !zero(p+48,8)) return MNG_CONTENT_INVALID;
    if (type==0x82 && (!zero(p+45,3) || (ext==16 && p[44]))) return MNG_CONTENT_INVALID;
    if (type==0x82 && ext==24 && (p[44] || u64(p+48))) return MNG_CONTENT_UNSUPPORTED;
    unsigned char digest[32]; struct mng_sha256 *hash=NULL;
    int bad=mng_sha256_init(&hash) || mng_sha256_update(hash,p,length-32) || mng_sha256_final(hash,digest);
    mng_sha256_free(hash);
    if (bad) return MNG_CONTENT_NOMEM;
    if (memcmp(digest,p+length-32,32)) return MNG_CONTENT_INTEGRITY;
    struct mng_content *meta=calloc(1,sizeof(*meta));
    if (!meta) return MNG_CONTENT_NOMEM;
    meta->title_id=u64(p);meta->version=u32(p+8);meta->type=(unsigned char)type;
    meta->attributes=p[20];meta->storage_id=p[21];meta->required_download_system_version=u32(p+24);
    meta->content_count=count;meta->dependency_count=dependencies;
    meta->application_id=type==0x80 ? meta->title_id:u64(p+32);
    if (!meta->application_id || (type!=0x80 && meta->application_id==meta->title_id)) { mng_content_free(meta);return MNG_CONTENT_INVALID; }
    if (type==0x80) {
        meta->patch_id=u64(p+32);meta->required_system_version=u32(p+40);
        meta->required_application_version=u32(p+44);
        if (meta->patch_id==meta->title_id) { mng_content_free(meta);return MNG_CONTENT_INVALID; }
    } else if (type==0x81) meta->required_system_version=u32(p+40);
    else meta->required_application_version=u32(p+40);
    meta->contents=calloc(count,sizeof(*meta->contents));
    meta->dependencies=calloc(dependencies ? dependencies:1,sizeof(*meta->dependencies));
    if (!meta->contents || !meta->dependencies) { mng_content_free(meta);return MNG_CONTENT_NOMEM; }
    enum mng_content_status status=MNG_CONTENT_OK;
    for (size_t i=0;i<count;i++) {
        const unsigned char *raw=p+32+ext+i*56;
        struct mng_content_record *r=meta->contents+i;
        memcpy(r->sha256,raw,32);memcpy(r->id,raw+32,16);
        /* Current ContentInfo has 40-bit size and an attribute byte; legacy
         * six-byte size remains identical for this <=128GiB supported subset. */
        r->size=u32(raw+48)|(uint64_t)raw[52]<<32;r->role=raw[54];r->id_offset=raw[55];
        if (raw[53] || r->role>5) { status=MNG_CONTENT_UNSUPPORTED;break; }
        if (!r->size || zero(r->sha256,32) || memcmp(r->id,r->sha256,16)) { status=MNG_CONTENT_INVALID;break; }
        if (r->size>NCA_LIMIT) { status=MNG_CONTENT_LIMIT;break; }
        for (size_t j=0;j<i;j++) if (!memcmp(r->id,meta->contents[j].id,16) ||
            (r->role==meta->contents[j].role && r->id_offset==meta->contents[j].id_offset)) {
            status=MNG_CONTENT_INVALID;break;
        }
        if (status) break;
    }
    for (size_t i=0;!status && i<dependencies;i++) {
        const unsigned char *raw=p+32+ext+(size_t)count*56+i*16;
        struct mng_content_dependency *d=meta->dependencies+i;
        d->title_id=u64(raw);d->version=u32(raw+8);d->type=raw[12];d->attributes=raw[13];
        if (!known(d->type) || (d->attributes&~7u)) { status=MNG_CONTENT_UNSUPPORTED;break; }
        if (!d->title_id || d->title_id==meta->title_id || !zero(raw+14,2)) { status=MNG_CONTENT_INVALID;break; }
        for (size_t j=0;j<i;j++) if (d->title_id==meta->dependencies[j].title_id) { status=MNG_CONTENT_INVALID;break; }
    }
    if (status) { mng_content_free(meta);return status; }
    *out=meta;return MNG_CONTENT_OK;
}
static int raw_role(unsigned role,unsigned nca) {
    switch (role) {
        case 0:return nca==1;
        case 1:return nca==0;
        case 2:return nca==4 || nca==5;
        case 3:return nca==2;
        case 4:case 5:return nca==3;
        default:return 0;
    }
}
struct candidate_index { const struct mng_content_candidate **entries;size_t count; };
static int candidate_compare(const void *left,const void *right) {
    const struct mng_content_candidate *const *a=left,*const *b=right;
    return memcmp((*a)->id,(*b)->id,16);
}
static enum mng_content_status index_candidates(const struct mng_content_candidate *candidates,
    size_t count,struct candidate_index *index) {
    index->entries=NULL;index->count=0;
    if (!candidates && count) return MNG_CONTENT_INVALID;
    if (count>CANDIDATE_LIMIT) return MNG_CONTENT_LIMIT;
    if (!count) return MNG_CONTENT_OK;
    const struct mng_content_candidate **entries=malloc(count*sizeof(*entries));
    if (!entries) return MNG_CONTENT_NOMEM;
    for (size_t i=0;i<count;i++) {
        const struct mng_content_candidate *c=candidates+i;
        if (!c->size || c->size>NCA_LIMIT || c->nca_type>5 || memcmp(c->id,c->sha256,16)) {
            free(entries);return MNG_CONTENT_INVALID;
        }
        entries[i]=c;
    }
    qsort(entries,count,sizeof(*entries),candidate_compare);
    for (size_t i=1;i<count;i++) if (!memcmp(entries[i-1]->id,entries[i]->id,16)) {
        free(entries);return MNG_CONTENT_INVALID;
    }
    index->entries=entries;index->count=count;return MNG_CONTENT_OK;
}
static const struct mng_content_candidate *candidate_find(const struct candidate_index *index,const unsigned char id[16]) {
    size_t left=0,right=index->count;
    while (left<right) {
        size_t middle=left+(right-left)/2;
        int order=memcmp(index->entries[middle]->id,id,16);
        if (order<0) left=middle+1;else right=middle;
    }
    return left<index->count && !memcmp(index->entries[left]->id,id,16) ? index->entries[left]:NULL;
}
static enum mng_content_status bind_records(const struct mng_content *meta,const struct candidate_index *index) {
    for (size_t i=0;i<meta->content_count;i++) {
        const struct mng_content_record *r=meta->contents+i;
        const struct mng_content_candidate *c=candidate_find(index,r->id);
        if (!c) return MNG_CONTENT_MISSING;
        if (c->size!=r->size || memcmp(c->sha256,r->sha256,32) || !raw_role(r->role,c->nca_type))
            return MNG_CONTENT_MISMATCH;
    }
    return MNG_CONTENT_OK;
}
enum mng_content_status mng_content_bind(const struct mng_content *meta,
    const struct mng_content_candidate *candidates,size_t count) {
    if (!meta || !meta->content_count || meta->content_count>CONTENT_LIMIT || !meta->contents) return MNG_CONTENT_INVALID;
    struct candidate_index index={0};
    enum mng_content_status status=index_candidates(candidates,count,&index);
    if (!status) status=bind_records(meta,&index);
    free(index.entries);return status;
}
static int selected_dependency(const struct mng_content *const *metadata,const size_t *selected,size_t count,
    const struct mng_content_dependency *dependency) {
    for (size_t i=0;i<count;i++) {
        const struct mng_content *m=metadata[selected[i]];
        if (m->title_id==dependency->title_id && m->version==dependency->version &&
            m->type==dependency->type && m->attributes==dependency->attributes)
            return (int)i;
    }
    return -1;
}
static int graph(const struct mng_content *const *metadata,const size_t *selected,size_t count,
    size_t index,unsigned char *state) {
    if (state[index]==1) return -1;
    if (state[index]==2) return 0;
    state[index]=1;
    const struct mng_content *meta=metadata[selected[index]];
    for (size_t i=0;i<meta->dependency_count;i++) {
        int next=selected_dependency(metadata,selected,count,meta->dependencies+i);
        if (next<0 || graph(metadata,selected,count,(size_t)next,state)) return -1;
    }
    state[index]=2;return 0;
}
enum mng_content_status mng_content_plan(const struct mng_content *const *metadata,size_t count,
    const struct mng_content_candidate *candidates,size_t candidate_count,uint64_t application,
    uint32_t cap,struct mng_content_plan *out) {
    if (!out || !application || !metadata || !count || (!candidates && candidate_count)) return MNG_CONTENT_INVALID;
    if (count>CATALOG_LIMIT || candidate_count>CANDIDATE_LIMIT) return MNG_CONTENT_LIMIT;
    struct mng_content_plan plan={0};plan.application_id=application;plan.base_index=plan.patch_index=SIZE_MAX;
    for (size_t i=0;i<count;i++) {
        const struct mng_content *m=metadata[i];
        if (!m || !known(m->type) || !m->content_count || m->content_count>CONTENT_LIMIT ||
            !m->contents || m->dependency_count>DEP_LIMIT || (m->dependency_count && !m->dependencies)) return MNG_CONTENT_INVALID;
        if (m->application_id!=application || (m->type==0x80 && m->title_id!=application)) return MNG_CONTENT_MISMATCH;
        for (size_t j=0;j<i;j++) if (m->title_id==metadata[j]->title_id &&
            (m->type!=metadata[j]->type || m->version==metadata[j]->version)) return MNG_CONTENT_INVALID;
        if (m->type==0x80 && m->version<=cap &&
            (plan.base_index==SIZE_MAX || m->version>metadata[plan.base_index]->version)) plan.base_index=i;
    }
    if (plan.base_index==SIZE_MAX) return MNG_CONTENT_MISSING;
    const struct mng_content *base=metadata[plan.base_index];
    for (size_t i=0;i<count;i++) if (metadata[i]->type==0x81) {
        const struct mng_content *m=metadata[i];
        if (!base->patch_id || m->title_id!=base->patch_id) return MNG_CONTENT_MISMATCH;
        if (m->version>=base->version && m->version<=cap &&
            (plan.patch_index==SIZE_MAX || m->version>metadata[plan.patch_index]->version)) plan.patch_index=i;
    }
    plan.version=plan.patch_index==SIZE_MAX ? base->version:metadata[plan.patch_index]->version;
    if (base->required_application_version>plan.version) return MNG_CONTENT_DEPENDENCY;
    for (size_t i=0;i<count;i++) if (metadata[i]->type==0x82) {
        size_t j=0;
        while (j<plan.dlc_count && metadata[plan.dlc_indices[j]]->title_id!=metadata[i]->title_id) ++j;
        if (j==plan.dlc_count) {
            if (plan.dlc_count==MNG_CONTENT_MAX_DLC) return MNG_CONTENT_LIMIT;
            plan.dlc_indices[plan.dlc_count++]=i;
        } else if (metadata[i]->version>metadata[plan.dlc_indices[j]]->version) plan.dlc_indices[j]=i;
    }
    for (size_t i=0;i<plan.dlc_count;i++) {
        if (metadata[plan.dlc_indices[i]]->required_application_version>plan.version) return MNG_CONTENT_DEPENDENCY;
        for (size_t j=i+1;j<plan.dlc_count;j++) if (metadata[plan.dlc_indices[j]]->title_id<metadata[plan.dlc_indices[i]]->title_id) {
            size_t swap=plan.dlc_indices[i];plan.dlc_indices[i]=plan.dlc_indices[j];plan.dlc_indices[j]=swap;
        }
    }
    struct candidate_index index={0};
    enum mng_content_status candidate_status=index_candidates(candidates,candidate_count,&index);
    if (candidate_status) return candidate_status;
    size_t selected[MNG_CONTENT_MAX_DLC+2], n=0;
    selected[n++]=plan.base_index;
    if (plan.patch_index!=SIZE_MAX) selected[n++]=plan.patch_index;
    for (size_t i=0;i<plan.dlc_count;i++) selected[n++]=plan.dlc_indices[i];
    unsigned char state[MNG_CONTENT_MAX_DLC+2]={0};
    for (size_t i=0;i<n;i++) {
        enum mng_content_status status=bind_records(metadata[selected[i]],&index);
        if (status) { free(index.entries);return status; }
        if (graph(metadata,selected,n,i,state)) { free(index.entries);return MNG_CONTENT_DEPENDENCY; }
    }
    free(index.entries);*out=plan;return MNG_CONTENT_OK;
}
const char *mng_content_status_name(enum mng_content_status status) {
    static const char *names[]={"ok","invalid","unsupported","limit","nomem","integrity","missing","mismatch","dependency"};
    return status>=MNG_CONTENT_OK && status<=MNG_CONTENT_DEPENDENCY ? names[status]:"unknown";
}
