/* BLAKE3 Internal Implementation Header
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
#ifndef BLAKE3_IMPL_H
#define BLAKE3_IMPL_H

#include <assert.h>
#include <stdbool.h>
#include <string.h>

#include "blake3.h"

/* Internal flags */
enum blake3_flags {
  CHUNK_START = 1 << 0,
  CHUNK_END = 1 << 1,
  PARENT = 1 << 2,
  ROOT = 1 << 3,
  KEYED_HASH = 1 << 4,
  DERIVE_KEY_CONTEXT = 1 << 5,
  DERIVE_KEY_MATERIAL = 1 << 6,
};

/* Internal constants */
static const uint32_t IV[8] = {
  0x6A09E667UL, 0xBB67AE85UL, 0x3C6EF372UL, 0xA54FF53AUL,
  0x510E527FUL, 0x9B05688CUL, 0x1F83D9ABUL, 0x5BE0CD19UL
};

static const uint8_t MSG_SCHEDULE[7][16] = {
  {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
  {2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8},
  {3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1},
  {10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6},
  {12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4},
  {9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7},
  {11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13},
};

/* Utility functions */
static inline uint32_t load32(const void *src) {
  const uint8_t *p = (const uint8_t *)src;
  return ((uint32_t)(p[0]) << 0) | ((uint32_t)(p[1]) << 8) |
         ((uint32_t)(p[2]) << 16) | ((uint32_t)(p[3]) << 24);
}

static inline void load_key_words(const uint8_t key[BLAKE3_KEY_LEN], uint32_t key_words[8]) {
  key_words[0] = load32(&key[0 * 4]);
  key_words[1] = load32(&key[1 * 4]);
  key_words[2] = load32(&key[2 * 4]);
  key_words[3] = load32(&key[3 * 4]);
  key_words[4] = load32(&key[4 * 4]);
  key_words[5] = load32(&key[5 * 4]);
  key_words[6] = load32(&key[6 * 4]);
  key_words[7] = load32(&key[7 * 4]);
}

static inline void store32(void *dst, uint32_t w) {
  uint8_t *p = (uint8_t *)dst;
  p[0] = (uint8_t)(w >> 0);
  p[1] = (uint8_t)(w >> 8);
  p[2] = (uint8_t)(w >> 16);
  p[3] = (uint8_t)(w >> 24);
}

static inline uint32_t rotr32(uint32_t w, uint32_t c) {
  return (w >> c) | (w << (32 - c));
}

/* Core compression function */
static inline void g(uint32_t *state, size_t a, size_t b, size_t c, size_t d, uint32_t x, uint32_t y) {
  state[a] = state[a] + state[b] + x;
  state[d] = rotr32(state[d] ^ state[a], 16);
  state[c] = state[c] + state[d];
  state[b] = rotr32(state[b] ^ state[c], 12);
  state[a] = state[a] + state[b] + y;
  state[d] = rotr32(state[d] ^ state[a], 8);
  state[c] = state[c] + state[d];
  state[b] = rotr32(state[b] ^ state[c], 7);
}

static inline void round_fn(uint32_t state[16], const uint32_t *msg, size_t round) {
  /* Mix columns */
  g(state, 0, 4, 8, 12, msg[MSG_SCHEDULE[round][0]], msg[MSG_SCHEDULE[round][1]]);
  g(state, 1, 5, 9, 13, msg[MSG_SCHEDULE[round][2]], msg[MSG_SCHEDULE[round][3]]);
  g(state, 2, 6, 10, 14, msg[MSG_SCHEDULE[round][4]], msg[MSG_SCHEDULE[round][5]]);
  g(state, 3, 7, 11, 15, msg[MSG_SCHEDULE[round][6]], msg[MSG_SCHEDULE[round][7]]);
  /* Mix diagonals */
  g(state, 0, 5, 10, 15, msg[MSG_SCHEDULE[round][8]], msg[MSG_SCHEDULE[round][9]]);
  g(state, 1, 6, 11, 12, msg[MSG_SCHEDULE[round][10]], msg[MSG_SCHEDULE[round][11]]);
  g(state, 2, 7, 8, 13, msg[MSG_SCHEDULE[round][12]], msg[MSG_SCHEDULE[round][13]]);
  g(state, 3, 4, 9, 14, msg[MSG_SCHEDULE[round][14]], msg[MSG_SCHEDULE[round][15]]);
}

static inline void compress(
    const uint32_t cv[8],
    const uint8_t block[BLAKE3_BLOCK_LEN],
    uint8_t block_len,
    uint64_t counter,
    uint8_t flags,
    uint8_t out[64]) {
  
  uint32_t block_words[16];
  for (size_t i = 0; i < 16; i++) {
    block_words[i] = load32(&block[i * 4]);
  }

  uint32_t state[16] = {
    cv[0], cv[1], cv[2], cv[3],
    cv[4], cv[5], cv[6], cv[7],
    IV[0], IV[1], IV[2], IV[3],
    (uint32_t)counter, (uint32_t)(counter >> 32), (uint32_t)block_len, (uint32_t)flags,
  };

  round_fn(state, block_words, 0);
  round_fn(state, block_words, 1);
  round_fn(state, block_words, 2);
  round_fn(state, block_words, 3);
  round_fn(state, block_words, 4);
  round_fn(state, block_words, 5);
  round_fn(state, block_words, 6);

  for (size_t i = 0; i < 8; i++) {
    store32(&out[i * 4], state[i] ^ state[i + 8]);
    store32(&out[(i + 8) * 4], state[i + 8] ^ cv[i]);
  }
}

typedef struct {
  uint32_t input_cv[8];
  uint8_t block[BLAKE3_BLOCK_LEN];
  uint8_t block_len;
  uint64_t counter;
  uint8_t flags;
} output_t;

static inline void chunk_state_init(blake3_hasher *self, const uint32_t key[8], uint8_t flags) {
  memcpy(self->cv, key, sizeof(self->cv));
  self->chunk_counter = 0;
  memset(self->buf, 0, BLAKE3_BLOCK_LEN);
  self->buf_len = 0;
  self->blocks_compressed = 0;
  self->flags = flags;
}

static inline void chunk_state_update(blake3_hasher *self, const uint8_t *input, size_t input_len) {
  while (input_len > 0) {
    if (self->buf_len == BLAKE3_BLOCK_LEN) {
      uint8_t block_flags = self->flags | (self->blocks_compressed == 0 ? CHUNK_START : 0);
      uint8_t out[64];
      compress(self->cv, self->buf, BLAKE3_BLOCK_LEN, self->chunk_counter, block_flags, out);
      memcpy(self->cv, out, 32);
      self->blocks_compressed += 1;
      self->buf_len = 0;
    }

    size_t want = BLAKE3_BLOCK_LEN - self->buf_len;
    size_t take = input_len < want ? input_len : want;
    memcpy(&self->buf[self->buf_len], input, take);
    self->buf_len += (uint8_t)take;
    input += take;
    input_len -= take;
  }
}

static inline void chunk_state_output(const blake3_hasher *self, output_t *output) {
  uint8_t block_flags = self->flags | (self->blocks_compressed == 0 ? CHUNK_START : 0) | CHUNK_END;
  memcpy(output->input_cv, self->cv, 32);
  memcpy(output->block, self->buf, BLAKE3_BLOCK_LEN);
  output->block_len = self->buf_len;
  output->counter = self->chunk_counter;
  output->flags = block_flags;
}

static inline void output_chaining_value(const output_t *self, uint8_t cv[32]) {
  compress(self->input_cv, self->block, self->block_len, self->counter, self->flags, cv);
}

static inline void output_root_bytes(const output_t *self, uint64_t seek, uint8_t *out, size_t out_len) {
  uint64_t output_block_counter = seek / 64;
  size_t offset_within_block = seek % 64;
  uint8_t wide_buf[64];

  while (out_len > 0) {
    compress(self->input_cv, self->block, self->block_len, output_block_counter, self->flags | ROOT, wide_buf);
    size_t available = 64 - offset_within_block;
    size_t memcpy_len = out_len < available ? out_len : available;
    memcpy(out, &wide_buf[offset_within_block], memcpy_len);
    out += memcpy_len;
    out_len -= memcpy_len;
    output_block_counter += 1;
    offset_within_block = 0;
  }
}

#endif /* BLAKE3_IMPL_H */

