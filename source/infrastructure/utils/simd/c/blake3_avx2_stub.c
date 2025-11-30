/* Stub for x86 AVX2 on ARM */
#include "blake3_simd.h"
#include <stdbool.h>
void blake3_compress_avx2(const uint32_t cv[8], const uint8_t block[64], uint8_t block_len, uint64_t counter, uint8_t flags, uint8_t out[64]) {
    extern void blake3_compress_portable(const uint32_t cv[8], const uint8_t block[64], uint8_t block_len, uint64_t counter, uint8_t flags, uint8_t out[64]);
    blake3_compress_portable(cv, block, block_len, counter, flags, out);
}
void blake3_hash_many_avx2(const uint8_t* const* inputs, size_t num_inputs, size_t blocks, const uint32_t key[8], uint64_t counter, bool increment_counter, uint8_t flags, uint8_t flags_start, uint8_t flags_end, uint8_t* out) {
    extern void blake3_hash_many_portable(const uint8_t* const* inputs, size_t num_inputs, size_t blocks, const uint32_t key[8], uint64_t counter, bool increment_counter, uint8_t flags, uint8_t flags_start, uint8_t flags_end, uint8_t* out);
    blake3_hash_many_portable(inputs, num_inputs, blocks, key, counter, increment_counter, flags, flags_start, flags_end, out);
}
