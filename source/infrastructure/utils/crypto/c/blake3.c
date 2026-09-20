/* BLAKE3 C Implementation - Portable version
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
 *
 * Upstream's two-space formatting is preserved on purpose - see the
 * .clang-format in this directory.
 */

#include "blake3.h"
#include "blake3_impl.h"

const char *blake3_version(void) {
  return BLAKE3_VERSION_STRING;
}

void blake3_hasher_init(blake3_hasher *self) {
  chunk_state_init(self, IV, 0);
}

void blake3_hasher_init_keyed(blake3_hasher *self, const uint8_t key[BLAKE3_KEY_LEN]) {
  uint32_t key_words[8];
  load_key_words(key, key_words);
  chunk_state_init(self, key_words, KEYED_HASH);
}

void blake3_hasher_init_derive_key_raw(blake3_hasher *self, const void *context, size_t context_len) {
  blake3_hasher context_hasher;
  chunk_state_init(&context_hasher, IV, DERIVE_KEY_CONTEXT);
  blake3_hasher_update(&context_hasher, context, context_len);
  
  output_t output;
  chunk_state_output(&context_hasher, &output);
  
  uint8_t context_key[BLAKE3_KEY_LEN];
  output_root_bytes(&output, 0, context_key, BLAKE3_KEY_LEN);
  
  uint32_t context_key_words[8];
  load_key_words(context_key, context_key_words);
  chunk_state_init(self, context_key_words, DERIVE_KEY_MATERIAL);
}

void blake3_hasher_init_derive_key(blake3_hasher *self, const char *context) {
  blake3_hasher_init_derive_key_raw(self, context, strlen(context));
}

void blake3_hasher_update(blake3_hasher *self, const void *input, size_t input_len) {
  const uint8_t *input_bytes = (const uint8_t *)input;
  
  while (input_len > 0) {
    /* If buffer has a partial chunk, try to fill it */
    if (self->buf_len > 0) {
      size_t want = BLAKE3_CHUNK_LEN - (self->blocks_compressed * BLAKE3_BLOCK_LEN + self->buf_len);
      size_t take = input_len < want ? input_len : want;
      chunk_state_update(self, input_bytes, take);
      input_bytes += take;
      input_len -= take;
      
      /* Check if chunk is complete */
      if (self->blocks_compressed * BLAKE3_BLOCK_LEN + self->buf_len == BLAKE3_CHUNK_LEN) {
        output_t output;
        chunk_state_output(self, &output);
        uint8_t chunk_cv[32];
        output_chaining_value(&output, chunk_cv);
        
        /* Start new chunk */
        self->chunk_counter += 1;
        chunk_state_init(self, (uint32_t *)self->cv, self->flags);
        memcpy(self->cv, chunk_cv, 32);
      }
    }
    
    /* Process complete chunks */
    while (input_len > BLAKE3_CHUNK_LEN) {
      chunk_state_update(self, input_bytes, BLAKE3_CHUNK_LEN);
      output_t output;
      chunk_state_output(self, &output);
      uint8_t chunk_cv[32];
      output_chaining_value(&output, chunk_cv);
      
      /* Start new chunk */
      self->chunk_counter += 1;
      chunk_state_init(self, (uint32_t *)self->cv, self->flags);
      memcpy(self->cv, chunk_cv, 32);
      
      input_bytes += BLAKE3_CHUNK_LEN;
      input_len -= BLAKE3_CHUNK_LEN;
    }
    
    /* Process remaining bytes */
    if (input_len > 0) {
      chunk_state_update(self, input_bytes, input_len);
      break;
    }
  }
}

void blake3_hasher_finalize(const blake3_hasher *self, uint8_t *out, size_t out_len) {
  blake3_hasher_finalize_seek(self, 0, out, out_len);
}

void blake3_hasher_finalize_seek(const blake3_hasher *self, uint64_t seek, uint8_t *out, size_t out_len) {
  output_t output;
  chunk_state_output(self, &output);
  output_root_bytes(&output, seek, out, out_len);
}

void blake3_hasher_reset(blake3_hasher *self) {
  uint8_t flags = self->flags;
  if (flags & KEYED_HASH) {
    /* Cannot reset keyed hasher without key - would need to store it */
    chunk_state_init(self, IV, 0);
  } else if (flags & DERIVE_KEY_MATERIAL) {
    /* Cannot reset derive key hasher without context */
    chunk_state_init(self, IV, 0);
  } else {
    chunk_state_init(self, IV, 0);
  }
}

