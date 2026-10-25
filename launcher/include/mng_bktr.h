#ifndef MNG_BKTR_H
#define MNG_BKTR_H
#include <stddef.h>
#include <stdint.h>
/* Original bounded BKTR virtual reader. No file ownership, publication,
 * executable loading, signatures or title compatibility inferred. */
enum mng_bktr_status { MNG_BKTR_OK, MNG_BKTR_INVALID, MNG_BKTR_IO,
    MNG_BKTR_UNSUPPORTED, MNG_BKTR_LIMIT, MNG_BKTR_NOMEM,
    MNG_BKTR_CANCELLED, MNG_BKTR_INTEGRITY };
struct mng_bktr_source {
    void *context;
    uint64_t size;
    /* Exact read:0success, nonzero failure. Caller retains stable source. */
    int (*read_at)(void *,uint64_t offset,void *,size_t length);
};
struct mng_bktr_config {
    /* Base is the FULL decrypted original IVFC section, including hash levels,
     * not the raw romfs.bin final level. It may be a bounded decryption adapter. */
    struct mng_bktr_source base;
    struct mng_bktr_source patch_nca; /* encrypted entire NCA, NCA-relative offsets */
    uint64_t section_offset, section_size;
    unsigned char key[16];
    const unsigned char *fs_header; /*512 bytes, already NCA-header-hash checked */
};
struct mng_bktr_callbacks {
    void *context;
    int (*cancelled)(void *);
    /* Optional before/after reads/open/verification. Nonzero means source
     * identity changed. Caller must also validate source identity at publication. */
    int (*check_sources)(void *);
    void (*progress)(void *,const char *phase,uint64_t done,uint64_t total);
};
struct mng_bktr;
/* BKTRv1/two-level16KiB tables,<=262144 entries each, combined tables<=32MiB,
 * source/virtual size<=128GiB, final RomFS<=64GiB. Copies and clears key state.
 * Callbacks must not mutate inputs/reenter. API calls are caller-serialized. */
enum mng_bktr_status mng_bktr_open(const struct mng_bktr_config *,
    const struct mng_bktr_callbacks *,struct mng_bktr **out);
void mng_bktr_close(struct mng_bktr *);
uint64_t mng_bktr_size(const struct mng_bktr *);
/* Structural virtual reads, split at relocation and counter-subsection
 * boundaries. Directly usable as mng_read_at callback.0success/-1failure;
 * status records a sticky error. Output may be partial on error: discard it. */
int mng_bktr_read_at(void *,uint64_t offset,void *,size_t length);
enum mng_bktr_status mng_bktr_status(const struct mng_bktr *);
/* Verify all6 IVFC levels over the reconstructed virtual section, including
 * padded final blocks. Only then return the final raw RomFS range. */
enum mng_bktr_status mng_bktr_verify_ivfc(struct mng_bktr *);
enum mng_bktr_status mng_bktr_romfs_range(struct mng_bktr *,uint64_t *offset,uint64_t *size);
const char *mng_bktr_status_name(enum mng_bktr_status);
#endif
