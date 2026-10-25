#ifndef MNG_PREPARE_INTERNAL_H
#define MNG_PREPARE_INTERNAL_H
#include "mng_prepare.h"
/* Private adapter for a bounded, non-copying folder member view. The view may
 * contain a synthetic PFS0 table, but its bytes are NEVER identified as a
 * physical container/file SHA. read_at is exact and checks active member
 * stability; check_sources validates every snapshotted member/directory.
 * The folder producer must attach its real consumed-member inventory and
 * controlled metadata asset before exposing/publishing this result. */
struct mng_prepare_reader {
    void *context;
    uint64_t size;
    int (*read_at)(void *,uint64_t,void *,size_t);
    int (*check_sources)(void *);
};
int mng_prepare_result_empty(const struct mng_prepare_result *);
enum mng_prepare_status mng_prepare_nca_folder_reader(const struct mng_prepare_reader *,
    const struct mng_key_provider *,const struct mng_asset_sink *,struct mng_prepare_result *);
#endif
