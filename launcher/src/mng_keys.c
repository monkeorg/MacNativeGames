#include "mng_keys.h"
#include "mng_crypto.h"
#include <stdlib.h>
#include <string.h>

#define KEY_COUNT 4096u
#define KEY_BYTES 256u
#define TEXT_LIMIT (1024u*1024u)
struct entry { char name[64]; unsigned char bytes[KEY_BYTES]; size_t length; };
struct mng_keys { size_t count; struct entry entries[KEY_COUNT]; };
static int space(unsigned char c) { return c == ' ' || c == '\t'; }
static int namechar(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_';
}
static int hex(unsigned char c) {
    if (c >= '0' && c <= '9') return c-'0';
    if (c >= 'a' && c <= 'f') return c-'a'+10;
    if (c >= 'A' && c <= 'F') return c-'A'+10;
    return -1;
}
void mng_keys_free(struct mng_keys *keys) {
    if (!keys) return;
    mng_secure_clear(keys, sizeof(*keys));
    free(keys);
}
int mng_keys_parse(const void *text, size_t length, struct mng_keys **out) {
    if (!out) return -1;
    *out = NULL;
    if ((!text && length) || length > TEXT_LIMIT) return length > TEXT_LIMIT ? -2 : -1;
    const unsigned char *bytes = text;
    struct mng_keys *keys = calloc(1, sizeof(*keys));
    if (!keys) return -3;
    int status = 0;
    size_t at = 0;
    while (at < length && !status) {
        size_t start = at;
        while (at < length && bytes[at] != '\n') {
            if (!bytes[at]) { status = -1; break; }
            ++at;
        }
        if (status) break;
        size_t end = at;
        if (at < length) ++at;
        if (end > start && bytes[end-1] == '\r') --end;
        while (start < end && space(bytes[start])) ++start;
        if (start == end || bytes[start] == '#') continue;
        size_t name = start;
        while (start < end && namechar(bytes[start])) ++start;
        size_t namesize = start-name;
        if (!namesize || namesize > 63) { status = -1; break; }
        while (start < end && space(bytes[start])) ++start;
        if (start == end || bytes[start++] != '=') { status = -1; break; }
        while (start < end && space(bytes[start])) ++start;
        size_t value = start;
        while (start < end && hex(bytes[start]) >= 0) ++start;
        size_t digits = start-value;
        if (!digits || digits % 2 || digits/2 > KEY_BYTES) { status = -1; break; }
        while (start < end && space(bytes[start])) ++start;
        if (start < end && bytes[start] != '#') { status = -1; break; }
        if (keys->count == KEY_COUNT) { status = -2; break; }
        for (size_t i = 0; i < keys->count; ++i) {
            if (strlen(keys->entries[i].name) == namesize &&
                !memcmp(keys->entries[i].name, bytes+name, namesize)) { status = -1; break; }
        }
        if (status) break;
        struct entry *entry = &keys->entries[keys->count++];
        memcpy(entry->name, bytes+name, namesize);
        entry->length = digits/2;
        for (size_t i = 0; i < entry->length; ++i)
            entry->bytes[i] = (unsigned char)((hex(bytes[value+2*i]) << 4) | hex(bytes[value+2*i+1]));
    }
    if (status) { mng_keys_free(keys); return status; }
    *out = keys;
    return 0;
}
static int lookup(void *context, const char *name, unsigned char *bytes, size_t length) {
    struct mng_keys *keys = context;
    if (!keys || !name || !bytes || !length || length > KEY_BYTES) return -1;
    size_t n = 0;
    while (n < 64 && name[n]) ++n;
    if (!n || n == 64) return -1;
    for (size_t i = 0; i < keys->count; ++i) {
        struct entry *entry = &keys->entries[i];
        if (!strcmp(name, entry->name)) {
            if (entry->length != length) return -1;
            memcpy(bytes, entry->bytes, length);
            return 0;
        }
    }
    return -1;
}
struct mng_key_provider mng_keys_provider(struct mng_keys *keys) {
    return (struct mng_key_provider){ keys, lookup };
}
