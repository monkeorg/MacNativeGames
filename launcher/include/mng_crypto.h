#ifndef MNG_CRYPTO_H
#define MNG_CRYPTO_H
#include <stddef.h>
#include <stdint.h>
/* Standard primitives only. All operations return 0 on success, -1 on error.
 * SHA final consumes the state; free is required after success or failure.
 * No key material is logged. Exact in-place AES operation is supported;
 * otherwise CTR/XTS input and output must not overlap. Null data pointers are
 * allowed only for zero-length SHA update or CTR/XTS operation. Keys/counters
 * remain required for zero-length AES operations. */
struct mng_sha256;
int mng_sha256_init(struct mng_sha256 **out);
int mng_sha256_update(struct mng_sha256 *state, const void *bytes, size_t length);
int mng_sha256_final(struct mng_sha256 *state, unsigned char digest[32]);
void mng_sha256_free(struct mng_sha256 *state);
void mng_secure_clear(void *bytes, size_t length);
int mng_aes128_ecb_encrypt(const unsigned char key[16], const unsigned char input[16], unsigned char output[16]);
int mng_aes128_ecb_decrypt(const unsigned char key[16], const unsigned char input[16], unsigned char output[16]);
/* Big-endian 128-bit base counter + floor(byte_offset/16); arbitrary byte
 * alignment. Reject logical offset or counter wrap before writing any bytes. */
int mng_aes128_ctr(const unsigned char key[16], const unsigned char counter[16],
    uint64_t byte_offset, const void *input, void *output, size_t length);
/* AES-XTS with two 128-bit keys (data key, then tweak key), 512-byte sectors.
 * NCA tweak input is a big-endian 128-bit sector number (same convention as
 * extract_exefs.py), followed by standard XTS field multiplication. No stealing:
 * length must be a multiple of 512. Reject sector-number wrap. */
int mng_aes128_xts_decrypt(const unsigned char key[32], uint64_t first_sector,
    const void *input, void *output, size_t length);
#endif
