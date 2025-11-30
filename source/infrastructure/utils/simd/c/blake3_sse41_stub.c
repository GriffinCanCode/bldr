/* Stub for x86 SSE4.1 on ARM */
#include "blake3_simd.h"
void blake3_compress_sse41(const uint32_t cv[8], const uint8_t block[64], uint8_t block_len, uint64_t counter, uint8_t flags, uint8_t out[64]) {
    extern void blake3_compress_portable(const uint32_t cv[8], const uint8_t block[64], uint8_t block_len, uint64_t counter, uint8_t flags, uint8_t out[64]);
    blake3_compress_portable(cv, block, block_len, counter, flags, out);
}
