/*
 * E2EE Proxy API Implementation
 */

#include "e2ee_proxy_api.h"
#include "embedded_certs.h"
#include "secure_crypto.h"

/* ML-KEM-768 low-level API (from mlkem/api.h with KYBER_K=3) */
#define CRYPTO_PUBLICKEYBYTES  1184
#define CRYPTO_SECRETKEYBYTES  2400
#define CRYPTO_CIPHERTEXTBYTES 1088
#define CRYPTO_BYTES           32

extern int pqcrystals_kyber768_ref_keypair(uint8_t *pk, uint8_t *sk);
extern int pqcrystals_kyber768_ref_enc(uint8_t *ct, uint8_t *ss, const uint8_t *pk);
extern int pqcrystals_kyber768_ref_dec(uint8_t *ss, const uint8_t *ct, const uint8_t *sk);

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <zlib.h>
#include <stdatomic.h>

static atomic_int g_initialized = 0;

PROTECT_FULL
int e2ee_init(void) {
    if (atomic_exchange(&g_initialized, 1) != 0) {
        return 0;
    }

    secure_key_init();
    return 0;
}

PROTECT_FULL
int e2ee_get_cert_der(uint8_t *out, size_t *len) {
    if (!atomic_load(&g_initialized)) return -1;
    if (*len < EMBEDDED_CERT_LEN) {
        *len = EMBEDDED_CERT_LEN;
        return -1;
    }
    memcpy(out, EMBEDDED_CERT, EMBEDDED_CERT_LEN);
    *len = EMBEDDED_CERT_LEN;
    return 0;
}

PROTECT_FULL
int e2ee_get_intermediate_der(uint8_t *out, size_t *len) {
    if (!atomic_load(&g_initialized)) return -1;
    if (*len < EMBEDDED_INTERMEDIATE_LEN) {
        *len = EMBEDDED_INTERMEDIATE_LEN;
        return -1;
    }
    memcpy(out, EMBEDDED_INTERMEDIATE, EMBEDDED_INTERMEDIATE_LEN);
    *len = EMBEDDED_INTERMEDIATE_LEN;
    return 0;
}

PROTECT_FULL
int e2ee_get_root_der(uint8_t *out, size_t *len) {
    if (!atomic_load(&g_initialized)) return -1;
    if (*len < EMBEDDED_ROOT_LEN) {
        *len = EMBEDDED_ROOT_LEN;
        return -1;
    }
    memcpy(out, EMBEDDED_ROOT, EMBEDDED_ROOT_LEN);
    *len = EMBEDDED_ROOT_LEN;
    return 0;
}

PROTECT_FULL
int e2ee_get_privkey_der(uint8_t *out, size_t *len) {
    if (!atomic_load(&g_initialized)) return -1;
    if (*len < EMBEDDED_PRIVKEY_LEN) {
        *len = EMBEDDED_PRIVKEY_LEN;
        return -1;
    }
    memcpy(out, EMBEDDED_PRIVKEY, EMBEDDED_PRIVKEY_LEN);
    *len = EMBEDDED_PRIVKEY_LEN;
    return 0;
}

int e2ee_mlkem_keygen(uint8_t pk[E2EE_MLKEM_PK_SIZE],
                      uint8_t sk[E2EE_MLKEM_SK_SIZE]) {
    return pqcrystals_kyber768_ref_keypair(pk, sk);
}

int e2ee_mlkem_encapsulate(const uint8_t *pk,
                           uint8_t ct[E2EE_MLKEM_CT_SIZE],
                           uint8_t ss[E2EE_MLKEM_SS_SIZE]) {
    return pqcrystals_kyber768_ref_enc(ct, ss, pk);
}

int e2ee_mlkem_decapsulate(const uint8_t *sk,
                           const uint8_t ct[E2EE_MLKEM_CT_SIZE],
                           uint8_t ss[E2EE_MLKEM_SS_SIZE]) {
    return pqcrystals_kyber768_ref_dec(ss, ct, sk);
}

int e2ee_hkdf_sha256(const uint8_t *ikm, size_t ikm_len,
                     const uint8_t *salt, size_t salt_len,
                     const uint8_t *info, size_t info_len,
                     uint8_t *okm, size_t okm_len) {
    return hkdf(ikm, ikm_len, salt, salt_len, info, info_len, okm, okm_len);
}

int e2ee_chacha20_seal(const uint8_t key[32], const uint8_t nonce[12],
                       const uint8_t *plaintext, size_t pt_len,
                       uint8_t *ciphertext, uint8_t tag[16]) {
    memcpy(ciphertext, plaintext, pt_len);
    return chacha20_poly1305_seal(key, nonce, NULL, 0, ciphertext, pt_len, tag);
}

int e2ee_chacha20_open(const uint8_t key[32], const uint8_t nonce[12],
                       const uint8_t *ciphertext, size_t ct_len,
                       const uint8_t tag[16], uint8_t *plaintext) {
    memcpy(plaintext, ciphertext, ct_len);
    return chacha20_poly1305_open(key, nonce, NULL, 0, plaintext, ct_len, tag);
}

size_t e2ee_gzip_compress(const uint8_t *in, size_t in_len,
                          uint8_t *out, size_t out_max) {
    z_stream strm;
    memset(&strm, 0, sizeof(strm));

    if (deflateInit2(&strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                     15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return 0;
    }

    strm.next_in = (Bytef *)in;
    strm.avail_in = (uInt)in_len;
    strm.next_out = (Bytef *)out;
    strm.avail_out = (uInt)out_max;

    int ret = deflate(&strm, Z_FINISH);
    size_t compressed_size = strm.total_out;
    deflateEnd(&strm);

    if (ret != Z_STREAM_END) return 0;
    return compressed_size;
}

size_t e2ee_gzip_decompress(const uint8_t *in, size_t in_len,
                            uint8_t *out, size_t out_max) {
    z_stream strm;
    memset(&strm, 0, sizeof(strm));

    if (inflateInit2(&strm, 15 + 32) != Z_OK) {
        return 0;
    }

    strm.next_in = (Bytef *)in;
    strm.avail_in = (uInt)in_len;
    strm.next_out = (Bytef *)out;
    strm.avail_out = (uInt)out_max;

    int ret = inflate(&strm, Z_FINISH);
    size_t decompressed_size = strm.total_out;
    inflateEnd(&strm);

    if (ret != Z_STREAM_END) return 0;
    return decompressed_size;
}

void e2ee_random_bytes(uint8_t *out, size_t len) {
    FILE *f = fopen("/dev/urandom", "rb");
    if (f) {
        size_t rd = fread(out, 1, len, f);
        fclose(f);
        if (rd == len) return;
    }
    abort();
}
