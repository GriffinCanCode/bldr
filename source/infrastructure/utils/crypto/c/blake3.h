/* BLAKE3 C API - Header
 *
 * Ported from the official BLAKE3 reference implementation:
 *   https://github.com/BLAKE3-team/BLAKE3
 *
 * Copyright (c) 2019-2020 Jack O'Connor, Jean-Philippe Aumasson,
 *                         Samuel Neves, Zooko Wilcox-O'Hearn
 *
 * Upstream is triple-licensed; bldr redistributes under CC0-1.0:
 *   CC0-1.0 OR Apache-2.0 OR Apache-2.0 WITH LLVM-exception
 *
 * This file is third-party code. The surrounding project is under the
 * Griffin License v1.0, which does not apply here. See NOTICE at the
 * repository root.
 */

#ifndef BLAKE3_H
#define BLAKE3_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BLAKE3_VERSION_STRING "1.5.0"
#define BLAKE3_KEY_LEN 32
#define BLAKE3_OUT_LEN 32
#define BLAKE3_BLOCK_LEN 64
#define BLAKE3_CHUNK_LEN 1024
#define BLAKE3_MAX_DEPTH 54

/* This struct is a private implementation detail. */
typedef struct {
  uint32_t cv[8];
  uint64_t chunk_counter;
  uint8_t buf[BLAKE3_BLOCK_LEN];
  uint8_t buf_len;
  uint8_t blocks_compressed;
  uint8_t flags;
} blake3_hasher;

const char *blake3_version(void);

void blake3_hasher_init(blake3_hasher *self);
void blake3_hasher_init_keyed(blake3_hasher *self, const uint8_t key[BLAKE3_KEY_LEN]);
void blake3_hasher_init_derive_key(blake3_hasher *self, const char *context);
void blake3_hasher_init_derive_key_raw(blake3_hasher *self, const void *context, size_t context_len);
void blake3_hasher_update(blake3_hasher *self, const void *input, size_t input_len);
void blake3_hasher_finalize(const blake3_hasher *self, uint8_t *out, size_t out_len);
void blake3_hasher_finalize_seek(const blake3_hasher *self, uint64_t seek, uint8_t *out, size_t out_len);
void blake3_hasher_reset(blake3_hasher *self);

#ifdef __cplusplus
}
#endif

#endif /* BLAKE3_H */

