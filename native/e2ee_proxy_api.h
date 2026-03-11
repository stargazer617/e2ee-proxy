/*
 * E2EE Proxy API - shared library for nginx/lua proxy
 */

#ifndef E2EE_PROXY_API_H
#define E2EE_PROXY_API_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Initialization */
int e2ee_init(void);

/* TLS Certificate & Key Retrieval (DER format) */
int e2ee_get_cert_der(uint8_t *out, size_t *len);
int e2ee_get_intermediate_der(uint8_t *out, size_t *len);
int e2ee_get_root_der(uint8_t *out, size_t *len);
int e2ee_get_privkey_der(uint8_t *out, size_t *len);

/* ML-KEM-768 Post-Quantum Key Encapsulation */

#define E2EE_MLKEM_PK_SIZE   1184
#define E2EE_MLKEM_SK_SIZE   2400
#define E2EE_MLKEM_CT_SIZE   1088
#define E2EE_MLKEM_SS_SIZE   32

int e2ee_mlkem_keygen(uint8_t pk[E2EE_MLKEM_PK_SIZE],
                      uint8_t sk[E2EE_MLKEM_SK_SIZE]);

int e2ee_mlkem_encapsulate(const uint8_t *pk,
                           uint8_t ct[E2EE_MLKEM_CT_SIZE],
                           uint8_t ss[E2EE_MLKEM_SS_SIZE]);

int e2ee_mlkem_decapsulate(const uint8_t *sk,
                           const uint8_t ct[E2EE_MLKEM_CT_SIZE],
                           uint8_t ss[E2EE_MLKEM_SS_SIZE]);

/* HKDF-SHA256 Key Derivation */
int e2ee_hkdf_sha256(const uint8_t *ikm, size_t ikm_len,
                     const uint8_t *salt, size_t salt_len,
                     const uint8_t *info, size_t info_len,
                     uint8_t *okm, size_t okm_len);

/* ChaCha20-Poly1305 AEAD */
int e2ee_chacha20_seal(const uint8_t key[32], const uint8_t nonce[12],
                       const uint8_t *plaintext, size_t pt_len,
                       uint8_t *ciphertext, uint8_t tag[16]);

int e2ee_chacha20_open(const uint8_t key[32], const uint8_t nonce[12],
                       const uint8_t *ciphertext, size_t ct_len,
                       const uint8_t tag[16], uint8_t *plaintext);

/* Gzip Compression */
size_t e2ee_gzip_compress(const uint8_t *in, size_t in_len,
                          uint8_t *out, size_t out_max);

size_t e2ee_gzip_decompress(const uint8_t *in, size_t in_len,
                            uint8_t *out, size_t out_max);

/* Random Bytes (CSPRNG) */
void e2ee_random_bytes(uint8_t *out, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* E2EE_PROXY_API_H */
