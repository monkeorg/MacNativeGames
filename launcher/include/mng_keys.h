#ifndef MNG_KEYS_H
#define MNG_KEYS_H
#include "mng_prepare.h"
/* Ephemeral bounded prod.keys text; no file I/O, logging or serialization.
 * Caller retains/clears its input buffer. Provider remains valid until free.
 * Names: lowercase ASCII letters/digits/underscore, <=63 bytes. Values: even
 * nonempty hex, <=256 bytes. # comments and ASCII space/tab/CRLF supported.
 * Duplicates are rejected even if identical. Maximum input1MiB /4096 entries.
 * Parse returns0, -1invalid, -2limit, -3allocation; *out is NULL on failure. */
struct mng_keys;
int mng_keys_parse(const void *text, size_t length, struct mng_keys **out);
struct mng_key_provider mng_keys_provider(struct mng_keys *keys);
void mng_keys_free(struct mng_keys *keys);
#endif
