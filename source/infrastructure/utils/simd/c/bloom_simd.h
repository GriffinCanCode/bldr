/* SIMD-Accelerated Bloom Filter Probing
 * Vectorized bit probing using AVX2/AVX-512 gather instructions
 * 
 * Design: Check 4-8 hash positions simultaneously using SIMD gather
 * - AVX2: Process 4 hashes in parallel (256-bit)
 * - AVX-512: Process 8 hashes in parallel (512-bit)
 * - 2x throughput improvement for batch queries
 * 
 * Separation of Concerns: This module handles only SIMD probing logic
 * Core Bloom filter logic remains in bloom.c
 */

#ifndef BLOOM_SIMD_H
#define BLOOM_SIMD_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "bloom.h"

#ifdef __cplusplus
extern "C" {
#endif

/* SIMD capability levels for Bloom filter operations */
typedef enum {
    BLOOM_SIMD_NONE,      /* Scalar fallback */
    BLOOM_SIMD_AVX2,      /* 4 hashes parallel */
    BLOOM_SIMD_AVX512     /* 8 hashes parallel */
} bloom_simd_level_t;

/* Get optimal SIMD level for current CPU */
bloom_simd_level_t bloom_get_simd_level(void);

/* Get human-readable SIMD level name */
const char* bloom_simd_level_name(bloom_simd_level_t level);

/* === SIMD Vectorized Probing ===
 * 
 * These functions check multiple hashes simultaneously using SIMD gather.
 * The k hash positions for each input hash are computed via double hashing,
 * then all bits are gathered and tested in parallel.
 */

/* Probe 4 hashes using AVX2 (256-bit)
 * Returns: 4-bit mask where bit i = may_contain(hashes[i])
 * Requires: AVX2 support, count <= 4
 */
uint32_t bloom_probe_avx2_4(
    const bloom_filter_t* filter,
    const uint64_t hashes[4]
);

/* Probe 8 hashes using AVX-512 (512-bit)  
 * Returns: 8-bit mask where bit i = may_contain(hashes[i])
 * Requires: AVX-512F + AVX-512VL support, count <= 8
 */
uint32_t bloom_probe_avx512_8(
    const bloom_filter_t* filter,
    const uint64_t hashes[8]
);

/* === Auto-dispatching SIMD batch probing ===
 * 
 * Automatically selects optimal SIMD path based on CPU capabilities.
 * Falls back to scalar for unsupported hardware.
 */

/* Probe batch with auto SIMD dispatch
 * Returns: bitmask where bit i = may_contain(hashes[i])
 * Max 64 hashes per call
 */
uint64_t bloom_probe_simd_batch(
    const bloom_filter_t* filter,
    const uint64_t* hashes,
    size_t count
);

/* Count matches with SIMD-accelerated probing
 * Returns: number of hashes that may be present
 */
size_t bloom_count_matches_simd(
    const bloom_filter_t* filter,
    const uint64_t* hashes,
    size_t count
);

/* === Single hash SIMD-accelerated probing ===
 * 
 * For single queries, SIMD is used to check all k hash positions
 * in parallel within a single query (not multiple queries).
 */

/* Check single hash with SIMD-parallel bit testing
 * All k bit positions tested simultaneously using SIMD
 */
bool bloom_probe_single_simd(
    const bloom_filter_t* filter,
    uint64_t hash
);

#ifdef __cplusplus
}
#endif

#endif /* BLOOM_SIMD_H */

