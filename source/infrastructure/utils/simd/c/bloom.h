/* SIMD-Accelerated Bloom Filter
 * Cache-oblivious, GC-free implementation for betterC compatibility
 * 
 * Design: Split-block Bloom filter with SIMD-accelerated bit operations
 * - Uses k independent hash functions via double hashing
 * - Block-aligned for cache efficiency
 * - Constant-time operations regardless of filter size
 * 
 * Performance: 2-4x faster than scalar on AVX2, 1.5-2x on NEON
 */

#ifndef BLOOM_H
#define BLOOM_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Bloom filter structure (opaque to D layer) */
typedef struct bloom_filter {
    uint64_t* bits;           /* Bit array (64-bit aligned) */
    size_t num_bits;          /* Total bits (rounded to 64) */
    size_t num_words;         /* Number of 64-bit words */
    uint32_t num_hashes;      /* Number of hash functions (k) */
    size_t num_items;         /* Items added (for stats) */
    bool owns_memory;         /* Whether we allocated bits */
} bloom_filter_t;

/* Statistics */
typedef struct bloom_stats {
    size_t num_bits;          /* Total bits */
    size_t num_items;         /* Items added */
    uint32_t num_hashes;      /* Hash functions */
    double fill_ratio;        /* Fraction of bits set */
    double false_positive_rate; /* Estimated FPR */
    size_t memory_bytes;      /* Memory usage */
} bloom_stats_t;

/* === Core Operations === */

/* Calculate optimal parameters for given capacity and error rate */
void bloom_optimal_params(
    size_t expected_items,    /* Expected number of items */
    double error_rate,        /* Target false positive rate (e.g., 0.01) */
    size_t* out_num_bits,     /* Output: optimal bit count */
    uint32_t* out_num_hashes  /* Output: optimal hash count */
);

/* Initialize bloom filter with specified parameters */
int bloom_init(
    bloom_filter_t* filter,
    size_t num_bits,
    uint32_t num_hashes
);

/* Initialize with external buffer (no allocation) */
int bloom_init_with_buffer(
    bloom_filter_t* filter,
    uint64_t* buffer,
    size_t buffer_words,
    uint32_t num_hashes
);

/* Free bloom filter resources */
void bloom_free(bloom_filter_t* filter);

/* Reset filter to empty state (all zeros) */
void bloom_reset(bloom_filter_t* filter);

/* === Insert/Query Operations (SIMD-accelerated) === */

/* Insert item by hash (primary interface) */
void bloom_insert_hash(bloom_filter_t* filter, uint64_t hash);

/* Insert item by two hashes (for double hashing) */
void bloom_insert_hashes(bloom_filter_t* filter, uint64_t h1, uint64_t h2);

/* Insert raw bytes (computes hash internally) */
void bloom_insert(bloom_filter_t* filter, const uint8_t* data, size_t len);

/* Check if item might be present */
bool bloom_may_contain_hash(const bloom_filter_t* filter, uint64_t hash);

/* Check with two hashes */
bool bloom_may_contain_hashes(const bloom_filter_t* filter, uint64_t h1, uint64_t h2);

/* Check raw bytes */
bool bloom_may_contain(const bloom_filter_t* filter, const uint8_t* data, size_t len);

/* === Batch Operations (SIMD-accelerated) === */

/* Insert multiple items at once */
void bloom_insert_batch(
    bloom_filter_t* filter,
    const uint64_t* hashes,
    size_t count
);

/* Check multiple items at once 
 * Returns: bitmask where bit i = may_contain(hashes[i])
 * Max 64 items per call (returns uint64_t mask)
 */
uint64_t bloom_may_contain_batch(
    const bloom_filter_t* filter,
    const uint64_t* hashes,
    size_t count  /* max 64 */
);

/* Count how many items in batch might be present */
size_t bloom_count_matches(
    const bloom_filter_t* filter,
    const uint64_t* hashes,
    size_t count
);

/* === Statistics & Utilities === */

/* Get filter statistics */
bloom_stats_t bloom_get_stats(const bloom_filter_t* filter);

/* Estimate current false positive rate */
double bloom_estimate_fpr(const bloom_filter_t* filter);

/* Count set bits (population count) */
size_t bloom_popcount(const bloom_filter_t* filter);

/* Merge two filters (OR operation) */
int bloom_merge(bloom_filter_t* dest, const bloom_filter_t* src);

/* Serialize filter to bytes */
size_t bloom_serialize_size(const bloom_filter_t* filter);
int bloom_serialize(const bloom_filter_t* filter, uint8_t* buffer, size_t buffer_size);

/* Deserialize filter from bytes */
int bloom_deserialize(bloom_filter_t* filter, const uint8_t* buffer, size_t buffer_size);

#ifdef __cplusplus
}
#endif

#endif /* BLOOM_H */

