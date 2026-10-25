#ifndef MNG_FOLDER_H
#define MNG_FOLDER_H
#include "mng_prepare.h"
enum mng_folder_kind { MNG_FOLDER_NCA=1, MNG_FOLDER_ASSETS=2 };
struct mng_folder_callbacks {
    void *context;
    /* Trusted NFC+Unicode-casefold component canonicalizer for RomFS names.
     * Without it, non-ASCII names inside a plaintext image are unsupported.
     * Input member filenames themselves use a bounded ASCII grammar. */
    int (*canonical_name)(void *,const char *,char *,size_t);
};
/* Shallow layout detection only; no decryption, identity or compatibility.
 * NCA: flat .nca/.tik/.cert/.xml members. Assets: exefs/{main,main.npdm,
 * rtld,sdk,subsdk0..9} and romfs/romfs.bin, as existing Mac extraction emits.
 * Ambiguous layouts refuse. Unknown reports never establish identity. */
enum mng_prepare_status mng_folder_kind_fd(int directory_fd,enum mng_folder_kind *);
/* Directory descriptor remains open/unrepositioned. Reads only consumed
 * relative members, never an absolute path from imported metadata. <=512
 * members/128GiB, <=128-byte member names, <=127 ExeFS assets. At most four
 * internal source descriptors are open concurrently (root/exefs/romfs/member).
 * Keys required only for NCA. No original container is fabricated or copied:
 * a bounded table-only read view reuses the native NCA pipeline.
 * Fingerprinting reads every consumed member before preparation; this extra
 * read cost is real. Final input-members.json contains sorted names,size,SHA
 * only. Its exact canonical bytes bind member_inventory_sha256, not fileSHA.
 * Plain assets receive bounded NSO header/file-range checks, actual NPDM
 * META/ACI0 program-ID parsing and full RomFS structural indexing. This does
 * not validate NSO execution, NPDM signatures, NCA integrity or compatibility;
 * plaintext keeps exefs_verified/romfs_verified zero. asset_hashes_verified
 * records the bytes actually copied, not an independent authenticity claim.
 * All errors leave caller-owned unpublished staging; caller discards it.
 * Source directories must stay stable; callbacks cannot mutate or reenter. */
enum mng_prepare_status mng_prepare_folder_fd(int directory_fd,enum mng_folder_kind,
    const struct mng_key_provider *,const struct mng_folder_callbacks *,
    const struct mng_asset_sink *,struct mng_prepare_result *);
#endif
