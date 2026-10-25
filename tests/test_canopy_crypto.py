"""Native standard crypto/key parsing checked with public vectors and an oracle.

No real keys or game inputs. On Apple this compiles the CommonCrypto provider;
on Linux OpenSSL supplies primitives. cryptography is a separate mode oracle.
"""
import ctypes as C
import hashlib
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile
import unittest

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

ROOT = Path(__file__).resolve().parents[1]
U8 = C.c_ubyte
PTR = C.POINTER(U8)
LOOKUP = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_char_p, PTR, C.c_size_t)


class Provider(C.Structure):
    _fields_ = [('context', C.c_void_p), ('lookup', LOOKUP)]


def buf(data):
    return (U8 * len(data)).from_buffer_copy(data)


class NativeCrypto(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')
        if not compiler:
            raise unittest.SkipTest('C compiler required')
        cls.temp = tempfile.TemporaryDirectory()
        library = Path(cls.temp.name)/'crypto.so'
        command = [compiler, '-std=c11', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
                   '-I'+str(ROOT/'launcher/include'), '-dynamiclib' if sys.platform == 'darwin' else '-shared']
        if sys.platform != 'darwin':
            command += ['-fPIC']
        command += [str(ROOT/'launcher/src/mng_crypto.c'), str(ROOT/'launcher/src/mng_keys.c')]
        if sys.platform != 'darwin':
            command += ['-lcrypto']
        subprocess.run(command+['-o', str(library)], check=True, capture_output=True, text=True)
        cls.lib = C.CDLL(str(library))
        signatures = {
            'mng_sha256_init': ([C.POINTER(C.c_void_p)], C.c_int),
            'mng_sha256_update': ([C.c_void_p, C.c_void_p, C.c_size_t], C.c_int),
            'mng_sha256_final': ([C.c_void_p, PTR], C.c_int),
            'mng_sha256_free': ([C.c_void_p], None),
            'mng_secure_clear': ([C.c_void_p, C.c_size_t], None),
            'mng_aes128_ecb_encrypt': ([PTR, PTR, PTR], C.c_int),
            'mng_aes128_ecb_decrypt': ([PTR, PTR, PTR], C.c_int),
            'mng_aes128_ctr': ([PTR, PTR, C.c_uint64, C.c_void_p, C.c_void_p, C.c_size_t], C.c_int),
            'mng_aes128_xts_decrypt': ([PTR, C.c_uint64, C.c_void_p, C.c_void_p, C.c_size_t], C.c_int),
            'mng_keys_parse': ([C.c_void_p, C.c_size_t, C.POINTER(C.c_void_p)], C.c_int),
            'mng_keys_provider': ([C.c_void_p], Provider),
            'mng_keys_free': ([C.c_void_p], None),
        }
        for name, (arguments, result) in signatures.items():
            method = getattr(cls.lib, name)
            method.argtypes, method.restype = arguments, result

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_sha_public_vectors_and_streaming_lifecycle(self):
        for message in (b'', b'abc', b'a'*1_000_000, bytes(range(256))*40):
            state, output = C.c_void_p(), (U8*32)()
            self.assertEqual(self.lib.mng_sha256_init(C.byref(state)), 0)
            try:
                if C.sizeof(C.c_size_t) == 8:
                    self.assertEqual(self.lib.mng_sha256_update(state, buf(b'x'), 1 << 61), -1)
                self.assertEqual(self.lib.mng_sha256_update(state, None, 0), 0)
                for start in range(0, len(message), 113):
                    chunk = message[start:start+113]
                    self.assertEqual(self.lib.mng_sha256_update(state, buf(chunk), len(chunk)), 0)
                self.assertEqual(self.lib.mng_sha256_final(state, output), 0)
                self.assertEqual(bytes(output), hashlib.sha256(message).digest())
                self.assertEqual(self.lib.mng_sha256_final(state, output), -1)
                self.assertEqual(self.lib.mng_sha256_update(state, None, 0), -1)
            finally:
                self.lib.mng_sha256_free(state)
        self.assertEqual(self.lib.mng_sha256_init(None), -1)
        self.assertEqual(self.lib.mng_sha256_update(None, None, 0), -1)
        self.lib.mng_sha256_free(None)

    def test_aes_ecb_fips197_vector_and_in_place(self):
        key = buf(bytes.fromhex('000102030405060708090a0b0c0d0e0f'))
        plain = bytes.fromhex('00112233445566778899aabbccddeeff')
        cipher = bytes.fromhex('69c4e0d86a7b0430d8cdb78070b4c55a')
        block = buf(plain)
        self.assertEqual(self.lib.mng_aes128_ecb_encrypt(key, block, block), 0)
        self.assertEqual(bytes(block), cipher)
        self.assertEqual(self.lib.mng_aes128_ecb_decrypt(key, block, block), 0)
        self.assertEqual(bytes(block), plain)
        self.assertEqual(self.lib.mng_aes128_ecb_encrypt(None, block, block), -1)
        self.assertEqual(self.lib.mng_aes128_ecb_decrypt(key, None, block), -1)

    def test_ctr_nist_sp800_38a_vector(self):
        key = buf(bytes.fromhex('2b7e151628aed2a6abf7158809cf4f3c'))
        counter = buf(bytes.fromhex('f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff'))
        plain = bytes.fromhex('6bc1bee22e409f96e93d7e117393172a')
        output = (U8*16)()
        self.assertEqual(self.lib.mng_aes128_ctr(key, counter, 0, buf(plain), output, 16), 0)
        self.assertEqual(bytes(output).hex(), '874d6191b620e3261bef6864990db6ce')

    def test_ctr_unaligned_offsets_and_chunked_in_place_against_oracle(self):
        rng = random.Random(85456)
        for offset in (0, 1, 15, 16, 17, 255, 65537, (1 << 40)+9):
            key, counter, plain = rng.randbytes(16), rng.randbytes(16), rng.randbytes(1031)
            adjusted = (int.from_bytes(counter, 'big')+offset//16).to_bytes(16, 'big')
            oracle = Cipher(algorithms.AES(key), modes.CTR(adjusted)).encryptor()
            expected = oracle.update(b'\0'*(offset % 16)+plain)[offset % 16:] + oracle.finalize()
            block = buf(plain)
            for start in range(0, len(plain), 79):
                n = min(79, len(plain)-start)
                pointer = C.byref(block, start)
                self.assertEqual(self.lib.mng_aes128_ctr(buf(key), buf(counter), offset+start,
                                                       pointer, pointer, n), 0)
            self.assertEqual(bytes(block), expected)
            self.assertEqual(self.lib.mng_aes128_ctr(buf(key), buf(counter), offset, block, block, len(plain)), 0)
            self.assertEqual(bytes(block), plain)

    def test_ctr_refuses_counter_offset_wrap_and_partial_overlap_without_output(self):
        key, counter, data, output = buf(bytes(16)), buf(b'\xff'*16), buf(bytes(32)), buf(b'Q'*32)
        for offset, n in ((0, 17), (16, 1), ((1 << 64)-1, 2)):
            self.assertEqual(self.lib.mng_aes128_ctr(key, counter, offset, data, output, n), -1)
            self.assertEqual(bytes(output), b'Q'*32)
        self.assertEqual(self.lib.mng_aes128_ctr(key, counter, 0, None, None, 0), 0)
        self.assertEqual(self.lib.mng_aes128_ctr(None, counter, 0, None, None, 0), -1)
        self.assertEqual(self.lib.mng_aes128_ctr(key, counter, 0, None, output, 1), -1)
        self.assertEqual(self.lib.mng_aes128_ctr(key, counter, 0, output, C.byref(output, 1), 16), -1)
        self.assertEqual(bytes(output), b'Q'*32)

    def test_nca_xts_big_endian_sectors_against_independent_mode(self):
        rng = random.Random(2018)
        key = rng.randbytes(32)
        for sector, sectors in ((0, 6), (1, 2), (5, 1), (0x0102030405060708, 3), ((1 << 64)-1, 1)):
            plain = rng.randbytes(512*sectors)
            ciphertext = bytearray()
            for i in range(sectors):
                oracle = Cipher(algorithms.AES(key), modes.XTS((sector+i).to_bytes(16, 'big'))).encryptor()
                ciphertext += oracle.update(plain[512*i:512*(i+1)])+oracle.finalize()
            block = buf(ciphertext)
            self.assertEqual(self.lib.mng_aes128_xts_decrypt(buf(key), sector, block, block, len(block)), 0)
            self.assertEqual(bytes(block), plain)

    def test_xts_refuses_partial_sector_wrap_and_overlapping_buffers(self):
        key, block = buf(bytes(range(32))), buf(b'Q'*1024)
        for sector, n in ((0, 1), (0, 511), (0, 513), ((1 << 64)-1, 1024)):
            self.assertEqual(self.lib.mng_aes128_xts_decrypt(key, sector, block, block, n), -1)
            self.assertEqual(bytes(block), b'Q'*1024)
        self.assertEqual(self.lib.mng_aes128_xts_decrypt(key, 0, None, None, 0), 0)
        self.assertEqual(self.lib.mng_aes128_xts_decrypt(None, 0, None, None, 0), -1)
        self.assertEqual(self.lib.mng_aes128_xts_decrypt(key, 0, block, C.byref(block, 1), 512), -1)
        self.assertEqual(bytes(block), b'Q'*1024)

    def parse(self, text, status=0):
        keys = C.c_void_p(123)
        actual = self.lib.mng_keys_parse(buf(text), len(text), C.byref(keys))
        self.assertEqual(actual, status)
        if status:
            self.assertIsNone(keys.value)
        return keys

    def test_ephemeral_keys_comments_lookup_exact_lengths_and_clear(self):
        text = b'# invented keys only\r\n header_key = '+bytes(range(32)).hex().encode()+b' # comment\n\tkey_area_key_application_00=00112233445566778899AABBCCDDEEFF\n'
        keys = self.parse(text)
        try:
            provider = self.lib.mng_keys_provider(keys)
            output = buf(b'Q'*32)
            self.assertEqual(provider.lookup(provider.context, b'header_key', output, 32), 0)
            self.assertEqual(bytes(output), bytes(range(32)))
            for name, length in ((b'header_key', 16), (b'missing', 32), (b'', 32), (b'a'*64, 32)):
                output = buf(b'Q'*32)
                self.assertEqual(provider.lookup(provider.context, name, output, length), -1)
                self.assertEqual(bytes(output), b'Q'*32)
            short = (U8*16)()
            self.assertEqual(provider.lookup(provider.context, b'key_area_key_application_00', short, 16), 0)
            self.assertEqual(bytes(short).hex(), '00112233445566778899aabbccddeeff')
        finally:
            self.lib.mng_keys_free(keys)
        secret = buf(bytes(range(256)))
        self.lib.mng_secure_clear(secret, len(secret))
        self.assertEqual(bytes(secret), bytes(256))
        self.lib.mng_keys_free(None)

    def test_key_parser_rejects_ambiguous_invalid_and_duplicate_text(self):
        invalid = (b'a=0', b'a=zz', b'a=', b'=00', b'a 00', b'a=00 garbage',
                   b'A=00', b'a-b=00', b'a=00\na=00', b'a=00\na=11', b'a\x00=00',
                   b'\xef\xbb\xbfa=00', b'a=00\rb=11', b'a'*64+b'=00', b'a='+b'00'*257)
        for text in invalid:
            with self.subTest(case=text[:20]):
                self.parse(text, -1)
        self.assertEqual(self.lib.mng_keys_parse(None, 1, C.byref(C.c_void_p())), -1)
        self.assertEqual(self.lib.mng_keys_parse(None, 0, None), -1)

    def test_key_parser_limits_and_empty_provider(self):
        keys = self.parse(b'')
        self.lib.mng_keys_free(keys)
        keys = self.parse(b'a='+b'55'*256)
        self.lib.mng_keys_free(keys)
        self.parse(b'#'+b'a'*(1024*1024), -2)
        self.parse(b''.join(f'key_{i}=00\n'.encode() for i in range(4097)), -2)


if __name__ == '__main__':
    unittest.main()
