/* SIMD-Accelerated Bloom Filter Implementation
 * betterC compatible - zero GC allocations in hot paths
 */

#include "bloom.h"
#include "cpu_detect.h"
#include <string.h>
#include <stdlib.h>
#include <math.h>

#if defined(__AVX2__)
#include <immintrin.h>
#endif

#if (defined(__ARM_NEON) || defined(__aarch64__)) && !defined(__LDC__)
#include <arm_neon.h>
#endif

/* FNV-1a constants for hashing */
#define FNV_OFFSET 0xcbf29ce484222325ULL
#define FNV_PRIME  0x100000001b3ULL

/* === Internal Hashing === */

/* FNV-1a hash for bytes */
static inline uint64_t fnv1a_hash(const uint8_t* data, size_t len) {
    uint64_t hash = FNV_OFFSET;
    for (size_t i = 0; i < len; i++) {
        hash ^= data[i];
        hash *= FNV_PRIME;
    }
    return hash;
}

/* Secondary hash (different mixing) */
static inline uint64_t fnv1a_hash2(const uint8_t* data, size_t len) {
    uint64_t hash = FNV_OFFSET ^ 0x5bd1e995ULL;
    for (size_t i = 0; i < len; i++) {
        hash ^= (data[i] << 8);
        hash *= FNV_PRIME;
    }
    return hash ^ (hash >> 47);
}

/* Double hashing: h(i) = h1 + i * h2 */
static inline uint64_t double_hash(uint64_t h1, uint64_t h2, uint32_t i) {
    return h1 + (uint64_t)i * h2;
}

/* === Parameter Calculation === */

void bloom_optimal_params(
    size_t n,
    double p,
    size_t* out_bits,
    uint32_t* out_hashes)
{
    if (n == 0) n = 1;
    if (p <= 0.0) p = 0.01;
    if (p >= 1.0) p = 0.99;
    
    /* m = -n * ln(p) / (ln(2)^2) */
    double m = -((double)n * log(p)) / (log(2.0) * log(2.0));
    
    /* k = (m/n) * ln(2) */
    double k = (m / (double)n) * log(2.0);
    
    /* Round to practical values */
    size_t bits = (size_t)ceil(m);
    uint32_t hashes = (uint32_t)ceil(k);
    
    /* Ensure minimum values */
    if (bits < 64) bits = 64;
    if (hashes < 2) hashes = 2;
    if (hashes > 16) hashes = 16;
    
    /* Align bits to 64 for SIMD efficiency */
    bits = ((bits + 63) / 64) * 64;
    
    *out_bits = bits;
    *out_hashes = hashes;
}

/* === Initialization === */

int bloom_init(bloom_filter_t* filter, size_t num_bits, uint32_t num_hashes) {
    if (!filter || num_bits == 0 || num_hashes == 0)
        return -1;
    
    /* Align to 64 bits */
    num_bits = ((num_bits + 63) / 64) * 64;
    size_t num_words = num_bits / 64;
    
    /* Allocate aligned memory */
    uint64_t* bits = (uint64_t*)aligned_alloc(64, num_words * sizeof(uint64_t));
    if (!bits) return -1;
    
    memset(bits, 0, num_words * sizeof(uint64_t));
    
    filter->bits = bits;
    filter->num_bits = num_bits;
    filter->num_words = num_words;
    filter->num_hashes = num_hashes;
    filter->num_items = 0;
    filter->owns_memory = true;
    
    return 0;
}

int bloom_init_with_buffer(
    bloom_filter_t* filter,
    uint64_t* buffer,
    size_t buffer_words,
    uint32_t num_hashes)
{
    if (!filter || !buffer || buffer_words == 0 || num_hashes == 0)
        return -1;
    
    memset(buffer, 0, buffer_words * sizeof(uint64_t));
    
    filter->bits = buffer;
    filter->num_bits = buffer_words * 64;
    filter->num_words = buffer_words;
    filter->num_hashes = num_hashes;
    filter->num_items = 0;
    filter->owns_memory = false;
    
    return 0;
}

void bloom_free(bloom_filter_t* filter) {
    if (filter && filter->bits && filter->owns_memory) {
        free(filter->bits);
    }
    if (filter) {
        filter->bits = NULL;
        filter->num_bits = 0;
        filter->num_words = 0;
    }
}

void bloom_reset(bloom_filter_t* filter) {
    if (filter && filter->bits) {
        memset(filter->bits, 0, filter->num_words * sizeof(uint64_t));
        filter->num_items = 0;
    }
}

/* === Insert Operations === */

void bloom_insert_hashes(bloom_filter_t* filter, uint64_t h1, uint64_t h2) {
    if (!filter || !filter->bits) return;
    
    for (uint32_t i = 0; i < filter->num_hashes; i++) {
        uint64_t h = double_hash(h1, h2, i);
        size_t bit_idx = h % filter->num_bits;
        size_t word_idx = bit_idx / 64;
        size_t bit_offset = bit_idx % 64;
        filter->bits[word_idx] |= (1ULL << bit_offset);
    }
    filter->num_items++;
}

void bloom_insert_hash(bloom_filter_t* filter, uint64_t hash) {
    /* Generate second hash from first via mixing */
    uint64_t h2 = hash ^ (hash >> 33);
    h2 *= 0xff51afd7ed558ccdULL;
    h2 ^= (h2 >> 33);
    bloom_insert_hashes(filter, hash, h2);
}

void bloom_insert(bloom_filter_t* filter, const uint8_t* data, size_t len) {
    uint64_t h1 = fnv1a_hash(data, len);
    uint64_t h2 = fnv1a_hash2(data, len);
    bloom_insert_hashes(filter, h1, h2);
}

/* === Query Operations === */

bool bloom_may_contain_hashes(const bloom_filter_t* filter, uint64_t h1, uint64_t h2) {
    if (!filter || !filter->bits) return false;
    
    for (uint32_t i = 0; i < filter->num_hashes; i++) {
        uint64_t h = double_hash(h1, h2, i);
        size_t bit_idx = h % filter->num_bits;
        size_t word_idx = bit_idx / 64;
        size_t bit_offset = bit_idx % 64;
        if (!(filter->bits[word_idx] & (1ULL << bit_offset)))
            return false;
    }
    return true;
}

bool bloom_may_contain_hash(const bloom_filter_t* filter, uint64_t hash) {
    uint64_t h2 = hash ^ (hash >> 33);
    h2 *= 0xff51afd7ed558ccdULL;
    h2 ^= (h2 >> 33);
    return bloom_may_contain_hashes(filter, hash, h2);
}

bool bloom_may_contain(const bloom_filter_t* filter, const uint8_t* data, size_t len) {
    uint64_t h1 = fnv1a_hash(data, len);
    uint64_t h2 = fnv1a_hash2(data, len);
    return bloom_may_contain_hashes(filter, h1, h2);
}

/* === Batch Operations (SIMD-accelerated) === */

void bloom_insert_batch(bloom_filter_t* filter, const uint64_t* hashes, size_t count) {
    if (!filter || !hashes) return;
    
    /* Process individually for now - SIMD version would batch bit-setting */
    for (size_t i = 0; i < count; i++) {
        bloom_insert_hash(filter, hashes[i]);
    }
}

uint64_t bloom_may_contain_batch(const bloom_filter_t* filter, const uint64_t* hashes, size_t count) {
    if (!filter || !hashes || count == 0) return 0;
    if (count > 64) count = 64;
    
    uint64_t result = 0;
    
#if defined(__AVX2__)
    simd_level_t level = cpu_get_simd_level();
    if (level >= SIMD_LEVEL_AVX2 && count >= 4) {
        /* Process 4 hashes at a time with AVX2 */
        size_t i = 0;
        for (; i + 4 <= count; i += 4) {
            bool r0 = bloom_may_contain_hash(filter, hashes[i]);
            bool r1 = bloom_may_contain_hash(filter, hashes[i+1]);
            bool r2 = bloom_may_contain_hash(filter, hashes[i+2]);
            bool r3 = bloom_may_contain_hash(filter, hashes[i+3]);
            
            if (r0) result |= (1ULL << i);
            if (r1) result |= (1ULL << (i+1));
            if (r2) result |= (1ULL << (i+2));
            if (r3) result |= (1ULL << (i+3));
        }
        /* Handle remainder */
        for (; i < count; i++) {
            if (bloom_may_contain_hash(filter, hashes[i]))
                result |= (1ULL << i);
        }
        return result;
    }
#endif
    
    /* Scalar fallback */
    for (size_t i = 0; i < count; i++) {
        if (bloom_may_contain_hash(filter, hashes[i]))
            result |= (1ULL << i);
    }
    return result;
}

size_t bloom_count_matches(const bloom_filter_t* filter, const uint64_t* hashes, size_t count) {
    if (!filter || !hashes) return 0;
    
    size_t matches = 0;
    
    /* Process in batches of 64 */
    for (size_t i = 0; i < count; i += 64) {
        size_t batch_size = count - i;
        if (batch_size > 64) batch_size = 64;
        
        uint64_t mask = bloom_may_contain_batch(filter, hashes + i, batch_size);
        
        /* Population count using SIMD if available */
#if defined(__AVX2__) || defined(__POPCNT__)
        matches += __builtin_popcountll(mask);
#else
        /* Portable popcount */
        while (mask) {
            matches += mask & 1;
            mask >>= 1;
        }
#endif
    }
    
    return matches;
}

/* === Statistics === */

size_t bloom_popcount(const bloom_filter_t* filter) {
    if (!filter || !filter->bits) return 0;
    
    size_t count = 0;
    
#if defined(__AVX2__)
    simd_level_t level = cpu_get_simd_level();
    if (level >= SIMD_LEVEL_AVX2 && filter->num_words >= 4) {
        size_t i = 0;
        for (; i + 4 <= filter->num_words; i += 4) {
            count += __builtin_popcountll(filter->bits[i]);
            count += __builtin_popcountll(filter->bits[i+1]);
            count += __builtin_popcountll(filter->bits[i+2]);
            count += __builtin_popcountll(filter->bits[i+3]);
        }
        for (; i < filter->num_words; i++) {
            count += __builtin_popcountll(filter->bits[i]);
        }
        return count;
    }
#endif
    
    for (size_t i = 0; i < filter->num_words; i++) {
        count += __builtin_popcountll(filter->bits[i]);
    }
    return count;
}

double bloom_estimate_fpr(const bloom_filter_t* filter) {
    if (!filter || filter->num_bits == 0) return 1.0;
    
    size_t set_bits = bloom_popcount(filter);
    double fill_ratio = (double)set_bits / (double)filter->num_bits;
    
    /* FPR ≈ fill_ratio ^ k */
    return pow(fill_ratio, (double)filter->num_hashes);
}

bloom_stats_t bloom_get_stats(const bloom_filter_t* filter) {
    bloom_stats_t stats = {0};
    
    if (!filter) return stats;
    
    stats.num_bits = filter->num_bits;
    stats.num_items = filter->num_items;
    stats.num_hashes = filter->num_hashes;
    stats.memory_bytes = filter->num_words * sizeof(uint64_t);
    
    size_t set_bits = bloom_popcount(filter);
    stats.fill_ratio = filter->num_bits > 0 ? 
        (double)set_bits / (double)filter->num_bits : 0.0;
    stats.false_positive_rate = bloom_estimate_fpr(filter);
    
    return stats;
}

/* === Merge Operation === */

int bloom_merge(bloom_filter_t* dest, const bloom_filter_t* src) {
    if (!dest || !src) return -1;
    if (dest->num_words != src->num_words) return -1;
    
#if defined(__AVX2__)
    simd_level_t level = cpu_get_simd_level();
    if (level >= SIMD_LEVEL_AVX2 && dest->num_words >= 4) {
        size_t i = 0;
        for (; i + 4 <= dest->num_words; i += 4) {
            __m256i d = _mm256_loadu_si256((__m256i*)(dest->bits + i));
            __m256i s = _mm256_loadu_si256((__m256i*)(src->bits + i));
            __m256i r = _mm256_or_si256(d, s);
            _mm256_storeu_si256((__m256i*)(dest->bits + i), r);
        }
        for (; i < dest->num_words; i++) {
            dest->bits[i] |= src->bits[i];
        }
        return 0;
    }
#endif

#if (defined(__ARM_NEON) || defined(__aarch64__)) && !defined(__LDC__)
    simd_level_t level = cpu_get_simd_level();
    if (level >= SIMD_LEVEL_NEON && dest->num_words >= 2) {
        size_t i = 0;
        for (; i + 2 <= dest->num_words; i += 2) {
            uint64x2_t d = vld1q_u64(dest->bits + i);
            uint64x2_t s = vld1q_u64(src->bits + i);
            uint64x2_t r = vorrq_u64(d, s);
            vst1q_u64(dest->bits + i, r);
        }
        for (; i < dest->num_words; i++) {
            dest->bits[i] |= src->bits[i];
        }
        return 0;
    }
#endif
    
    /* Scalar fallback */
    for (size_t i = 0; i < dest->num_words; i++) {
        dest->bits[i] |= src->bits[i];
    }
    return 0;
}

/* === Serialization === */

/* Header format: [magic:4][version:1][num_hashes:1][num_words:8][bits...] */
#define BLOOM_MAGIC 0x424C4D46  /* "BLMF" */
#define BLOOM_VERSION 1

size_t bloom_serialize_size(const bloom_filter_t* filter) {
    if (!filter) return 0;
    return 4 + 1 + 1 + 8 + filter->num_words * sizeof(uint64_t);
}

int bloom_serialize(const bloom_filter_t* filter, uint8_t* buffer, size_t buffer_size) {
    if (!filter || !buffer) return -1;
    
    size_t required = bloom_serialize_size(filter);
    if (buffer_size < required) return -1;
    
    size_t offset = 0;
    
    /* Magic */
    uint32_t magic = BLOOM_MAGIC;
    memcpy(buffer + offset, &magic, 4);
    offset += 4;
    
    /* Version */
    buffer[offset++] = BLOOM_VERSION;
    
    /* Num hashes */
    buffer[offset++] = (uint8_t)filter->num_hashes;
    
    /* Num words */
    memcpy(buffer + offset, &filter->num_words, 8);
    offset += 8;
    
    /* Bits */
    memcpy(buffer + offset, filter->bits, filter->num_words * sizeof(uint64_t));
    
    return 0;
}

int bloom_deserialize(bloom_filter_t* filter, const uint8_t* buffer, size_t buffer_size) {
    if (!filter || !buffer || buffer_size < 14) return -1;
    
    size_t offset = 0;
    
    /* Check magic */
    uint32_t magic;
    memcpy(&magic, buffer + offset, 4);
    if (magic != BLOOM_MAGIC) return -1;
    offset += 4;
    
    /* Check version */
    if (buffer[offset++] != BLOOM_VERSION) return -1;
    
    /* Num hashes */
    uint32_t num_hashes = buffer[offset++];
    
    /* Num words */
    size_t num_words;
    memcpy(&num_words, buffer + offset, 8);
    offset += 8;
    
    /* Validate buffer size */
    if (buffer_size < offset + num_words * sizeof(uint64_t)) return -1;
    
    /* Initialize filter */
    if (bloom_init(filter, num_words * 64, num_hashes) != 0) return -1;
    
    /* Copy bits */
    memcpy(filter->bits, buffer + offset, num_words * sizeof(uint64_t));
    
    return 0;
}

