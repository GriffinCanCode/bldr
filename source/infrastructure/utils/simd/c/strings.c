/* SIMD-Accelerated String Operations Implementation
 * 
 * Runtime-dispatched string comparison using SIMD instructions.
 * Follows the same patterns as simd_ops.c and bloom_simd.c.
 */

#include "strings.h"
#include "cpu_detect.h"
#include <string.h>

/* Include SIMD headers based on architecture */
#if defined(__AVX2__) || defined(__AVX512F__)
#include <immintrin.h>
#endif

#if defined(__SSE4_2__)
#include <nmmintrin.h>
#endif

/* Skip ARM NEON when using LDC's ImportC due to header compatibility issues */
#if (defined(__ARM_NEON) || defined(__aarch64__)) && !defined(__LDC__)
#include <arm_neon.h>
#define HAVE_NEON 1
#endif

/* === SIMD Level Detection === */

str_simd_level_t str_get_simd_level(void) {
    simd_level_t cpu_level = cpu_get_simd_level();
    
    if (cpu_level >= SIMD_LEVEL_AVX512)
        return STR_SIMD_AVX512;
    if (cpu_level >= SIMD_LEVEL_AVX2)
        return STR_SIMD_AVX2;
    if (cpu_level >= SIMD_LEVEL_SSE41)
        return STR_SIMD_SSE42;  /* SSE4.2 has string instructions */
    if (cpu_level >= SIMD_LEVEL_SSE2)
        return STR_SIMD_SSE2;
    if (cpu_level >= SIMD_LEVEL_NEON)
        return STR_SIMD_NEON;
    
    return STR_SIMD_NONE;
}

const char* str_simd_level_name(str_simd_level_t level) {
    switch (level) {
        case STR_SIMD_AVX512: return "AVX-512";
        case STR_SIMD_AVX2:   return "AVX2";
        case STR_SIMD_SSE42:  return "SSE4.2";
        case STR_SIMD_SSE2:   return "SSE2";
        case STR_SIMD_NEON:   return "NEON";
        default:              return "Scalar";
    }
}

/* === Scalar Fallback === */

static inline bool scalar_str_equal_len(const char* a, size_t len_a,
                                        const char* b, size_t len_b) {
    if (len_a != len_b) return false;
    return memcmp(a, b, len_a) == 0;
}

/* === AVX-512 Implementation (64 bytes per iteration) === */

#if defined(__AVX512F__) && defined(__AVX512BW__)

static bool avx512_str_equal_len(const char* a, size_t len_a,
                                 const char* b, size_t len_b) {
    if (len_a != len_b) return false;
    
    size_t len = len_a;
    size_t i = 0;
    
    /* Process 64 bytes at a time */
    for (; i + 64 <= len; i += 64) {
        __m512i va = _mm512_loadu_si512((__m512i*)(a + i));
        __m512i vb = _mm512_loadu_si512((__m512i*)(b + i));
        __mmask64 cmp = _mm512_cmpeq_epi8_mask(va, vb);
        
        if (cmp != 0xFFFFFFFFFFFFFFFFULL)
            return false;
    }
    
    /* Process 32-byte remainder with AVX2 */
    if (i + 32 <= len) {
        __m256i va = _mm256_loadu_si256((__m256i*)(a + i));
        __m256i vb = _mm256_loadu_si256((__m256i*)(b + i));
        __m256i cmp = _mm256_cmpeq_epi8(va, vb);
        int mask = _mm256_movemask_epi8(cmp);
        
        if (mask != -1)
            return false;
        i += 32;
    }
    
    /* Scalar for remaining bytes */
    return memcmp(a + i, b + i, len - i) == 0;
}

#endif /* __AVX512F__ && __AVX512BW__ */

/* === AVX2 Implementation (32 bytes per iteration) === */

#if defined(__AVX2__)

static bool avx2_str_equal_len(const char* a, size_t len_a,
                               const char* b, size_t len_b) {
    if (len_a != len_b) return false;
    
    size_t len = len_a;
    size_t i = 0;
    
    /* Process 32 bytes at a time */
    for (; i + 32 <= len; i += 32) {
        __m256i va = _mm256_loadu_si256((__m256i*)(a + i));
        __m256i vb = _mm256_loadu_si256((__m256i*)(b + i));
        __m256i cmp = _mm256_cmpeq_epi8(va, vb);
        int mask = _mm256_movemask_epi8(cmp);
        
        /* All 32 bytes must match (mask == 0xFFFFFFFF == -1) */
        if (mask != -1)
            return false;
    }
    
    /* Scalar for remaining < 32 bytes */
    return memcmp(a + i, b + i, len - i) == 0;
}

static bool avx2_str_starts_with(const char* str, size_t str_len,
                                 const char* prefix, size_t prefix_len) {
    if (prefix_len > str_len) return false;
    if (prefix_len == 0) return true;
    
    size_t i = 0;
    
    /* Process 32 bytes at a time */
    for (; i + 32 <= prefix_len; i += 32) {
        __m256i vs = _mm256_loadu_si256((__m256i*)(str + i));
        __m256i vp = _mm256_loadu_si256((__m256i*)(prefix + i));
        __m256i cmp = _mm256_cmpeq_epi8(vs, vp);
        int mask = _mm256_movemask_epi8(cmp);
        
        if (mask != -1)
            return false;
    }
    
    /* Scalar for remaining bytes */
    return memcmp(str + i, prefix + i, prefix_len - i) == 0;
}

static size_t avx2_str_find_first(const char* needle, size_t needle_len,
                                  const char* const* haystack, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (avx2_str_equal_len(needle, needle_len, haystack[i], strlen(haystack[i])))
            return i;
    }
    return (size_t)-1;
}

/* Constant-time comparison using AVX2 */
static bool avx2_str_constant_time_equal(const char* a, size_t len_a,
                                         const char* b, size_t len_b) {
    if (len_a != len_b) return false;
    
    size_t len = len_a;
    size_t i = 0;
    __m256i acc = _mm256_setzero_si256();
    
    /* Accumulate differences - never short-circuit */
    for (; i + 32 <= len; i += 32) {
        __m256i va = _mm256_loadu_si256((__m256i*)(a + i));
        __m256i vb = _mm256_loadu_si256((__m256i*)(b + i));
        __m256i xored = _mm256_xor_si256(va, vb);
        acc = _mm256_or_si256(acc, xored);
    }
    
    /* Reduce 256-bit accumulator */
    uint8_t diff = 0;
    uint8_t temp[32];
    _mm256_storeu_si256((__m256i*)temp, acc);
    for (size_t j = 0; j < 32; j++) {
        diff |= temp[j];
    }
    
    /* Process remaining bytes */
    for (; i < len; i++) {
        diff |= (uint8_t)(a[i] ^ b[i]);
    }
    
    return diff == 0;
}

#else

/* Stubs when AVX2 not compiled */
static bool avx2_str_equal_len(const char* a, size_t len_a,
                               const char* b, size_t len_b) {
    return scalar_str_equal_len(a, len_a, b, len_b);
}

static bool avx2_str_starts_with(const char* str, size_t str_len,
                                 const char* prefix, size_t prefix_len) {
    if (prefix_len > str_len) return false;
    return memcmp(str, prefix, prefix_len) == 0;
}

#endif /* __AVX2__ */

/* === NEON Implementation (16 bytes per iteration) === */

#if defined(HAVE_NEON)

static bool neon_str_equal_len(const char* a, size_t len_a,
                               const char* b, size_t len_b) {
    if (len_a != len_b) return false;
    
    size_t len = len_a;
    size_t i = 0;
    
    /* Process 16 bytes at a time */
    for (; i + 16 <= len; i += 16) {
        uint8x16_t va = vld1q_u8((const uint8_t*)(a + i));
        uint8x16_t vb = vld1q_u8((const uint8_t*)(b + i));
        uint8x16_t cmp = vceqq_u8(va, vb);
        
        /* All lanes must be 0xFF for equality */
        uint64x2_t cmp64 = vreinterpretq_u64_u8(cmp);
        if (vgetq_lane_u64(cmp64, 0) != ~0ULL || vgetq_lane_u64(cmp64, 1) != ~0ULL)
            return false;
    }
    
    /* Scalar for remaining bytes */
    return memcmp(a + i, b + i, len - i) == 0;
}

static bool neon_str_starts_with(const char* str, size_t str_len,
                                 const char* prefix, size_t prefix_len) {
    if (prefix_len > str_len) return false;
    if (prefix_len == 0) return true;
    
    size_t i = 0;
    
    for (; i + 16 <= prefix_len; i += 16) {
        uint8x16_t vs = vld1q_u8((const uint8_t*)(str + i));
        uint8x16_t vp = vld1q_u8((const uint8_t*)(prefix + i));
        uint8x16_t cmp = vceqq_u8(vs, vp);
        
        uint64x2_t cmp64 = vreinterpretq_u64_u8(cmp);
        if (vgetq_lane_u64(cmp64, 0) != ~0ULL || vgetq_lane_u64(cmp64, 1) != ~0ULL)
            return false;
    }
    
    return memcmp(str + i, prefix + i, prefix_len - i) == 0;
}

static bool neon_str_constant_time_equal(const char* a, size_t len_a,
                                         const char* b, size_t len_b) {
    if (len_a != len_b) return false;
    
    size_t len = len_a;
    size_t i = 0;
    uint8x16_t acc = vdupq_n_u8(0);
    
    for (; i + 16 <= len; i += 16) {
        uint8x16_t va = vld1q_u8((const uint8_t*)(a + i));
        uint8x16_t vb = vld1q_u8((const uint8_t*)(b + i));
        uint8x16_t xored = veorq_u8(va, vb);
        acc = vorrq_u8(acc, xored);
    }
    
    /* Reduce accumulator */
    uint8_t diff = 0;
    uint8_t temp[16];
    vst1q_u8(temp, acc);
    for (size_t j = 0; j < 16; j++) {
        diff |= temp[j];
    }
    
    /* Process remaining */
    for (; i < len; i++) {
        diff |= (uint8_t)(a[i] ^ b[i]);
    }
    
    return diff == 0;
}

#endif /* HAVE_NEON */

/* === Public API - Auto-dispatching === */

bool simd_str_equal(const char* a, const char* b) {
    if (a == b) return true;
    if (a == NULL || b == NULL) return false;
    
    size_t len_a = strlen(a);
    size_t len_b = strlen(b);
    
    return simd_str_equal_len(a, len_a, b, len_b);
}

bool simd_str_equal_len(const char* a, size_t len_a,
                        const char* b, size_t len_b) {
    /* Quick length check */
    if (len_a != len_b) return false;
    
    /* Same pointer means equal */
    if (a == b) return true;
    
    /* NULL check */
    if (a == NULL || b == NULL) return false;
    
    /* Empty strings are equal */
    if (len_a == 0) return true;
    
    /* Short string optimization - scalar is faster for small strings */
    if (len_a < 16) {
        return memcmp(a, b, len_a) == 0;
    }
    
    str_simd_level_t level = str_get_simd_level();
    
#if defined(__AVX512F__) && defined(__AVX512BW__)
    if (level >= STR_SIMD_AVX512 && len_a >= 64)
        return avx512_str_equal_len(a, len_a, b, len_b);
#endif

#if defined(__AVX2__)
    if (level >= STR_SIMD_AVX2 && len_a >= 32)
        return avx2_str_equal_len(a, len_a, b, len_b);
#endif

#if defined(HAVE_NEON)
    if (level >= STR_SIMD_NEON && len_a >= 16)
        return neon_str_equal_len(a, len_a, b, len_b);
#endif
    
    /* Scalar fallback */
    return memcmp(a, b, len_a) == 0;
}

bool simd_str_starts_with(const char* str, size_t str_len,
                          const char* prefix, size_t prefix_len) {
    if (prefix_len > str_len) return false;
    if (prefix_len == 0) return true;
    if (str == NULL || prefix == NULL) return false;
    
    /* Short prefix optimization */
    if (prefix_len < 16) {
        return memcmp(str, prefix, prefix_len) == 0;
    }
    
    str_simd_level_t level = str_get_simd_level();
    
#if defined(__AVX2__)
    if (level >= STR_SIMD_AVX2 && prefix_len >= 32)
        return avx2_str_starts_with(str, str_len, prefix, prefix_len);
#endif

#if defined(HAVE_NEON)
    if (level >= STR_SIMD_NEON && prefix_len >= 16)
        return neon_str_starts_with(str, str_len, prefix, prefix_len);
#endif
    
    return memcmp(str, prefix, prefix_len) == 0;
}

bool simd_str_ends_with(const char* str, size_t str_len,
                        const char* suffix, size_t suffix_len) {
    if (suffix_len > str_len) return false;
    if (suffix_len == 0) return true;
    if (str == NULL || suffix == NULL) return false;
    
    /* Point to where suffix would start */
    const char* suffix_start = str + (str_len - suffix_len);
    
    /* Reuse starts_with logic from the suffix position */
    return simd_str_equal_len(suffix_start, suffix_len, suffix, suffix_len);
}

size_t simd_str_find_first(const char* needle, size_t needle_len,
                           const char* const* haystack, size_t count) {
    if (needle == NULL || haystack == NULL || count == 0)
        return (size_t)-1;
    
#if defined(__AVX2__)
    str_simd_level_t level = str_get_simd_level();
    if (level >= STR_SIMD_AVX2)
        return avx2_str_find_first(needle, needle_len, haystack, count);
#endif
    
    /* Scalar fallback */
    for (size_t i = 0; i < count; i++) {
        if (simd_str_equal_len(needle, needle_len, haystack[i], strlen(haystack[i])))
            return i;
    }
    return (size_t)-1;
}

size_t simd_str_count_matches(const char* needle, size_t needle_len,
                              const char* const* strings, size_t count) {
    if (needle == NULL || strings == NULL || count == 0)
        return 0;
    
    size_t matches = 0;
    
    for (size_t i = 0; i < count; i++) {
        if (strings[i] != NULL && 
            simd_str_equal_len(needle, needle_len, strings[i], strlen(strings[i])))
            matches++;
    }
    
    return matches;
}

size_t simd_str_batch_equal(const char* needle, size_t needle_len,
                            const char* const* strings, const size_t* lengths,
                            size_t count, bool* results) {
    if (needle == NULL || strings == NULL || results == NULL || count == 0)
        return 0;
    
    size_t matches = 0;
    
    for (size_t i = 0; i < count; i++) {
        size_t str_len = lengths ? lengths[i] : (strings[i] ? strlen(strings[i]) : 0);
        results[i] = simd_str_equal_len(needle, needle_len, strings[i], str_len);
        if (results[i]) matches++;
    }
    
    return matches;
}

bool simd_path_equal(const char* a, size_t len_a, const char* b, size_t len_b) {
    if (a == NULL || b == NULL) return a == b;
    
    /* Strip trailing slashes for comparison */
    while (len_a > 1 && a[len_a - 1] == '/') len_a--;
    while (len_b > 1 && b[len_b - 1] == '/') len_b--;
    
    return simd_str_equal_len(a, len_a, b, len_b);
}

size_t simd_path_common_prefix(const char* a, size_t len_a,
                               const char* b, size_t len_b) {
    if (a == NULL || b == NULL || len_a == 0 || len_b == 0)
        return 0;
    
    size_t min_len = len_a < len_b ? len_a : len_b;
    size_t last_sep = 0;
    size_t i = 0;
    
    /* Find byte-by-byte common prefix, tracking last separator */
    for (; i < min_len; i++) {
        if (a[i] != b[i]) break;
        if (a[i] == '/') last_sep = i + 1;
    }
    
    /* If we reached the end of one path, check for separator */
    if (i == min_len) {
        if (i == len_a && (i == len_b || b[i] == '/'))
            return i;
        if (i == len_b && a[i] == '/')
            return i;
        return last_sep;
    }
    
    /* Return prefix up to last directory separator */
    return last_sep;
}

bool simd_str_equal_with_hash(const char* a, size_t len_a, uint64_t hash_a,
                              const char* b, size_t len_b, uint64_t hash_b) {
    /* Early exit on hash mismatch */
    if (hash_a != hash_b) return false;
    
    /* Hashes match - verify actual content */
    return simd_str_equal_len(a, len_a, b, len_b);
}

bool simd_str_constant_time_equal(const char* a, size_t len_a,
                                  const char* b, size_t len_b) {
    /* Length check must also be constant-time for security */
    /* We process both lengths and use XOR to check equality */
    volatile size_t len_diff = len_a ^ len_b;
    
    /* Use the shorter length to avoid buffer overrun */
    size_t len = len_a < len_b ? len_a : len_b;
    
    if (a == NULL || b == NULL) {
        return (a == NULL) && (b == NULL);
    }
    
    str_simd_level_t level = str_get_simd_level();
    
#if defined(__AVX2__)
    if (level >= STR_SIMD_AVX2 && len >= 32) {
        bool content_equal = avx2_str_constant_time_equal(a, len, b, len);
        return content_equal && (len_diff == 0);
    }
#endif

#if defined(HAVE_NEON)
    if (level >= STR_SIMD_NEON && len >= 16) {
        bool content_equal = neon_str_constant_time_equal(a, len, b, len);
        return content_equal && (len_diff == 0);
    }
#endif
    
    /* Portable constant-time fallback */
    volatile uint8_t diff = 0;
    for (size_t i = 0; i < len; i++) {
        diff |= (uint8_t)(a[i] ^ b[i]);
    }
    
    return (diff == 0) && (len_diff == 0);
}

