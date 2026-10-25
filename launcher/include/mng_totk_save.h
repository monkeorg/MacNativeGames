#ifndef MNG_TOTK_SAVE_H
#define MNG_TOTK_SAVE_H
#include <stddef.h>
#include <stdint.h>

/* Published MIT reference facts, not an exact1.4.3 discriminator or complete
 * game-save integrity contract. No checksum repair or active-save I/O. */
#define MNG_TOTK_SAVE_REFERENCE_SIZE 2307856u
#define MNG_TOTK_SAVE_REFERENCE_POLICY_MAX 999999u
#define MNG_TOTK_SAVE_REFERENCE_FAMILY "TOTK 1.4.x reference tuple"
enum mng_totk_save_status {
    MNG_TOTK_SAVE_OK=0, MNG_TOTK_SAVE_INVALID, MNG_TOTK_SAVE_SIGNATURE,
    MNG_TOTK_SAVE_STRUCTURE, MNG_TOTK_SAVE_POLICY
};
struct mng_totk_save_preview {
    size_t wallet_value_offset,terminator_offset;
    uint32_t wallet;
};
/* All outputs unchanged on refusal. The first aligned terminator bounds only
 * the interpreted simple-record prefix. Later payload is deliberately opaque.
 * Successful inspection means structural candidate only; exact version,
 * integrity and game compatibility remain unverified. Wallet is private data. */
enum mng_totk_save_status mng_totk_save_inspect(const void *bytes,size_t length,
    struct mng_totk_save_preview *out);
/* Separate caller-owned output of exactly reference size; overlapping source
 * and destination are refused. Changes only the discovered four-byte wallet.
 * Range is reference-editor UI POLICY, not a certified game-format limit.
 * Candidate must never be automatically imported/published as an active save. */
enum mng_totk_save_status mng_totk_save_candidate(const void *source,size_t length,
    uint32_t wallet,void *destination,size_t capacity);
#endif
