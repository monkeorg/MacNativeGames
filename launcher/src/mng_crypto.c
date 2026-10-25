#include "mng_crypto.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#ifdef __APPLE__
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#else
#include <openssl/evp.h>
#endif

void mng_secure_clear(void *bytes, size_t length) {
    volatile unsigned char *p = bytes;
    if (p) while (length--) *p++ = 0;
}

struct mng_sha256 {
    int finished;
    uint64_t bytes;
#ifdef __APPLE__
    CC_SHA256_CTX context;
#else
    EVP_MD_CTX *context;
#endif
};
#ifdef __APPLE__
/* CommonCrypto's public C digest interface is deprecated on macOS in favor
 * of Swift CryptoKit; the shared native C implementation deliberately uses it. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif
int mng_sha256_init(struct mng_sha256 **out) {
    if (!out) return -1;
    *out = NULL;
    struct mng_sha256 *state = calloc(1, sizeof(*state));
    if (!state) return -1;
#ifdef __APPLE__
    int ok = CC_SHA256_Init(&state->context);
#else
    state->context = EVP_MD_CTX_new();
    int ok = state->context && EVP_DigestInit_ex(state->context, EVP_sha256(), NULL);
#endif
    if (!ok) { mng_sha256_free(state); return -1; }
    *out = state;
    return 0;
}
int mng_sha256_update(struct mng_sha256 *state, const void *bytes, size_t length) {
    if (!state || state->finished || (!bytes && length) ||
        length > UINT64_MAX/8-state->bytes) return -1;
    if (!length) return 0;
    uint64_t total = state->bytes+length;
#ifdef __APPLE__
    const unsigned char *p = bytes;
    while (length) {
        CC_LONG n = length > UINT_MAX ? UINT_MAX : (CC_LONG)length;
        if (!CC_SHA256_Update(&state->context, p, n)) { state->finished = 1; return -1; }
        p += n; length -= n;
    }
#else
    if (!EVP_DigestUpdate(state->context, bytes, length)) { state->finished = 1; return -1; }
#endif
    state->bytes = total;
    return 0;
}
int mng_sha256_final(struct mng_sha256 *state, unsigned char digest[32]) {
    if (!state || state->finished || !digest) return -1;
    state->finished = 1;
    unsigned char temporary[32];
#ifdef __APPLE__
    int ok = CC_SHA256_Final(temporary, &state->context);
#else
    unsigned n = 0;
    int ok = EVP_DigestFinal_ex(state->context, temporary, &n) && n == 32;
#endif
    if (ok) memcpy(digest, temporary, 32);
    mng_secure_clear(temporary, sizeof(temporary));
    return ok ? 0 : -1;
}
void mng_sha256_free(struct mng_sha256 *state) {
    if (!state) return;
#ifndef __APPLE__
    EVP_MD_CTX_free(state->context);
#endif
    mng_secure_clear(state, sizeof(*state));
    free(state);
}
#ifdef __APPLE__
#pragma clang diagnostic pop
#endif

struct aes {
#ifdef __APPLE__
    CCCryptorRef context;
#else
    EVP_CIPHER_CTX *context;
#endif
};
static int aes_init(struct aes *state, const unsigned char key[16], int encrypt) {
#ifdef __APPLE__
    state->context = NULL;
    return CCCryptorCreate(encrypt ? kCCEncrypt : kCCDecrypt, kCCAlgorithmAES,
        kCCOptionECBMode, key, 16, NULL, &state->context) == kCCSuccess ? 0 : -1;
#else
    state->context = EVP_CIPHER_CTX_new();
    if (!state->context) return -1;
    return EVP_CipherInit_ex(state->context, EVP_aes_128_ecb(), NULL, key, NULL, encrypt) &&
           EVP_CIPHER_CTX_set_padding(state->context, 0) ? 0 : -1;
#endif
}
static void aes_free(struct aes *state) {
#ifdef __APPLE__
    if (state->context) CCCryptorRelease(state->context);
#else
    EVP_CIPHER_CTX_free(state->context);
#endif
    mng_secure_clear(state, sizeof(*state));
}
static int aes_block(struct aes *state, const unsigned char input[16], unsigned char output[16]) {
    unsigned char temporary[32];
#ifdef __APPLE__
    size_t n = 0;
    int ok = CCCryptorUpdate(state->context, input, 16, temporary, sizeof(temporary), &n) == kCCSuccess && n == 16;
#else
    int n = 0;
    int ok = EVP_CipherUpdate(state->context, temporary, &n, input, 16) && n == 16;
#endif
    if (ok) memcpy(output, temporary, 16);
    mng_secure_clear(temporary, sizeof(temporary));
    return ok ? 0 : -1;
}
static int ecb(const unsigned char key[16], const unsigned char input[16], unsigned char output[16], int encrypt) {
    if (!key || !input || !output) return -1;
    struct aes state = {0};
    int status = aes_init(&state, key, encrypt);
    if (!status) status = aes_block(&state, input, output);
    aes_free(&state);
    return status;
}
int mng_aes128_ecb_encrypt(const unsigned char key[16], const unsigned char input[16], unsigned char output[16]) {
    return ecb(key, input, output, 1);
}
int mng_aes128_ecb_decrypt(const unsigned char key[16], const unsigned char input[16], unsigned char output[16]) {
    return ecb(key, input, output, 0);
}
/* Add a bounded block index to a 128-bit big-endian counter. */
static int counter_add(unsigned char counter[16], uint64_t addend) {
    for (unsigned i = 16; i; --i) {
        unsigned n = counter[i-1] + (unsigned)(addend & 255);
        counter[i-1] = (unsigned char)n;
        addend = (addend >> 8) + (n >> 8);
    }
    return addend ? -1 : 0;
}
static int buffers_valid(const void *input, void *output, size_t length) {
    if (!length) return 1;
    if (!input || !output) return 0;
    uintptr_t from = (uintptr_t)input, to = (uintptr_t)output;
    if (length > UINTPTR_MAX-from || length > UINTPTR_MAX-to) return 0;
    return from == to || from+length <= to || to+length <= from;
}
int mng_aes128_ctr(const unsigned char key[16], const unsigned char counter[16],
    uint64_t byte_offset, const void *input, void *output, size_t length) {
    if (!key || !counter || !buffers_valid(input, output, length) || length > UINT64_MAX-byte_offset) return -1;
    if (!length) return 0;
    unsigned char block[16], stream[16];
    memcpy(block, counter, 16);
    /* Validate the last block before touching output, including unaligned ends. */
    if (counter_add(block, (byte_offset+length-1)/16)) { mng_secure_clear(block, 16); return -1; }
    memcpy(block, counter, 16);
    if (counter_add(block, byte_offset/16)) { mng_secure_clear(block, 16); return -1; }
    struct aes state = {0};
    int status = aes_init(&state, key, 1);
    const unsigned char *from = input;
    unsigned char *to = output;
    size_t skip = (size_t)(byte_offset % 16);
    while (!status && length) {
        status = aes_block(&state, block, stream);
        if (status) break;
        size_t n = length < 16-skip ? length : 16-skip;
        for (size_t i = 0; i < n; ++i) to[i] = from[i] ^ stream[skip+i];
        from += n; to += n; length -= n; skip = 0;
        if (length) status = counter_add(block, 1);
    }
    aes_free(&state);
    mng_secure_clear(block, sizeof(block));
    mng_secure_clear(stream, sizeof(stream));
    return status;
}
/* Standard XTS multiplication by x in GF(2^128), polynomial 0x87. */
static void tweak_next(unsigned char tweak[16]) {
    unsigned carry = 0;
    for (unsigned i = 0; i < 16; ++i) {
        unsigned next = tweak[i] >> 7;
        tweak[i] = (unsigned char)((tweak[i] << 1) | carry);
        carry = next;
    }
    tweak[0] ^= (unsigned char)(0x87 & (0u-carry));
}
int mng_aes128_xts_decrypt(const unsigned char key[32], uint64_t first_sector,
    const void *input, void *output, size_t length) {
    if (!key || !buffers_valid(input, output, length) || length % 512 ||
        (length && length/512-1 > UINT64_MAX-first_sector)) return -1;
    if (!length) return 0;
    struct aes data = {0}, tweak_cipher = {0};
    unsigned char tweak[16] = {0}, block[16] = {0};
    int status = aes_init(&data, key, 0);
    if (!status) status = aes_init(&tweak_cipher, key+16, 1);
    const unsigned char *from = input;
    unsigned char *to = output;
    while (!status && length) {
        memset(tweak, 0, sizeof(tweak));
        for (unsigned i = 0; i < 8; ++i) tweak[15-i] = (unsigned char)(first_sector >> (8*i));
        status = aes_block(&tweak_cipher, tweak, tweak);
        for (unsigned off = 0; !status && off < 512; off += 16) {
            for (unsigned i = 0; i < 16; ++i) block[i] = from[off+i] ^ tweak[i];
            status = aes_block(&data, block, block);
            if (status) break;
            for (unsigned i = 0; i < 16; ++i) to[off+i] = block[i] ^ tweak[i];
            tweak_next(tweak);
        }
        from += 512; to += 512; length -= 512;
        if (length) ++first_sector;
    }
    aes_free(&data); aes_free(&tweak_cipher);
    mng_secure_clear(tweak, sizeof(tweak)); mng_secure_clear(block, sizeof(block));
    return status;
}
