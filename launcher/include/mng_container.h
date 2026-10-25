#ifndef MNG_CONTAINER_H
#define MNG_CONTAINER_H
#include <stddef.h>
#include <stdint.h>

/* Read exactly length bytes at offset; return zero on success. Never writes to
 * the source. The caller owns source lifetime and detects concurrent mutation. */
typedef int (*mng_read_at)(void *context, uint64_t offset, void *bytes, size_t length);
enum mng_status { MNG_OK, MNG_INVALID, MNG_IO, MNG_LIMIT, MNG_NOMEM };
enum mng_kind { MNG_PFS0, MNG_HFS0, MNG_NSP, MNG_XCI };
#define MNG_MAX_ENTRIES 4096u
#define MNG_MAX_STRINGS (1024u * 1024u)
#define MNG_MAX_NAME 1024u
struct mng_entry { const char *name; uint64_t offset, size; };
struct mng_inventory {
    enum mng_kind kind;
    size_t count;
    struct mng_entry *entries;
    char *names;
};
/* Output must be empty on entry. On any failure it remains empty. Bounds refer
 * to the complete partition, including its header. HFS hashes are not verified:
 * successful inventory does not authenticate content or establish compatibility. */
enum mng_status mng_partition_inspect(mng_read_at read_at, void *context,
    uint64_t source_size, uint64_t offset, uint64_t bound,
    enum mng_kind kind, struct mng_inventory *output);
/* NSP or XCI secure-partition inventory only; no extraction or decryption. */
enum mng_status mng_container_inspect(mng_read_at read_at, void *context,
    uint64_t source_size, struct mng_inventory *output);
void mng_inventory_free(struct mng_inventory *inventory);
#endif
