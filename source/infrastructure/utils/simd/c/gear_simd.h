/* SIMD-Accelerated Gear Hash for FastCDC
 * 2-3x speedup via vectorized boundary detection
 * 
 * Architecture: AVX-512 → AVX2 → NEON → Portable fallback
 * 
 * Algorithm: Gear rolling hash with SIMD-accelerated:
 *   - Parallel gear table lookups (gather)
 *   - Vectorized fingerprint accumulation  
 *   - SIMD mask checks for boundary detection
 */

#ifndef BUILDER_GEAR_SIMD_H
#define BUILDER_GEAR_SIMD_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Gear hash configuration */
typedef struct {
    size_t min_size;    /* Minimum chunk size (skip boundary checks) */
    size_t avg_size;    /* Target average size (phase transition point) */
    size_t max_size;    /* Maximum chunk size (forced boundary) */
    uint64_t mask_s;    /* Strict mask (phase 1: min→avg) */
    uint64_t mask_l;    /* Lenient mask (phase 2: avg→max) */
} gear_config_t;

/* Pre-computed gear table (256 x 64-bit values) */
typedef struct {
    uint64_t table[256];
} gear_table_t;

/* Initialize gear table with deterministic PRNG (SplitMix64) */
void gear_init_table(gear_table_t* gt);

/* Find chunk boundary using SIMD-accelerated gear hash
 * Returns: offset of boundary (chunk length), or data_len if no boundary
 * 
 * Algorithm:
 *   1. Skip to min_size (no boundary possible)
 *   2. Phase 1 (min→avg): Strict mask, fewer boundaries
 *   3. Phase 2 (avg→max): Lenient mask, more boundaries
 *   4. Force boundary at max_size
 * 
 * SIMD acceleration:
 *   - AVX2: Process 4 bytes per iteration with gather
 *   - AVX-512: Process 8 bytes per iteration
 *   - NEON: Process 4 bytes with vtbl lookup
 */
size_t gear_find_boundary(
    const uint8_t* data,
    size_t data_len,
    size_t remaining,
    const gear_config_t* cfg,
    const gear_table_t* gt
);

/* Batch boundary detection for multiple buffers
 * Useful for parallel chunking of large files
 * Returns boundaries in out_boundaries array
 */
void gear_find_boundaries_batch(
    const uint8_t* const* data_ptrs,
    const size_t* data_lens,
    const size_t* remainings,
    size_t num_buffers,
    const gear_config_t* cfg,
    const gear_table_t* gt,
    size_t* out_boundaries
);

/* Compute mask bits from average size (log2) */
static inline uint32_t gear_mask_bits(size_t avg_size) {
    uint32_t bits = 0;
    while (avg_size > 1) { avg_size >>= 1; bits++; }
    return bits;
}

/* Create config from chunk size parameters */
static inline gear_config_t gear_make_config(size_t min, size_t avg, size_t max) {
    gear_config_t cfg;
    cfg.min_size = min;
    cfg.avg_size = avg;
    cfg.max_size = max;
    
    uint32_t bits = gear_mask_bits(avg);
    cfg.mask_s = (1ULL << (bits + 2)) - 1;  /* Stricter for small chunks */
    cfg.mask_l = (1ULL << (bits - 2)) - 1;  /* Relaxed for large chunks */
    
    return cfg;
}

/* Standard configurations */
static inline gear_config_t gear_config_artifact(void) {
    return gear_make_config(2048, 16384, 65536);   /* 2KB-16KB-64KB */
}

static inline gear_config_t gear_config_large(void) {
    return gear_make_config(8192, 65536, 262144);  /* 8KB-64KB-256KB */
}

static inline gear_config_t gear_config_small(void) {
    return gear_make_config(1024, 4096, 16384);    /* 1KB-4KB-16KB */
}

#ifdef __cplusplus
}
#endif

#endif /* BUILDER_GEAR_SIMD_H */

