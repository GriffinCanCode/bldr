/* SIMD-Accelerated String Operations
 * Hardware-agnostic string comparison optimized for dependency resolution
 * and path matching - critical hotspots in build systems.
 * 
 * Design:
 *   - Runtime CPU detection selects optimal implementation
 *   - AVX2: 32 bytes per cycle comparison (x86-64)
 *   - AVX-512: 64 bytes per cycle comparison (x86-64)
 *   - NEON: 16 bytes per cycle comparison (ARM64)
 *   - Portable fallback for unsupported hardware
 * 
 * Use Cases:
 *   - Path string comparison (O(n) → effectively O(n/32) on AVX2)
 *   - Dependency name matching
 *   - Cache key comparison
 *   - Target ID lookups
 * 
 * Performance:
 *   - 4-8x faster for strings >= 32 bytes on AVX2
 *   - 8-16x faster for strings >= 64 bytes on AVX-512
 *   - Negligible overhead for short strings (< 16 bytes)
 */

#ifndef BUILDER_SIMD_STRINGS_H
#define BUILDER_SIMD_STRINGS_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* SIMD capability levels for string operations */
typedef enum {
    STR_SIMD_NONE,      /* Portable scalar */
    STR_SIMD_SSE2,      /* 16-byte comparison */
    STR_SIMD_SSE42,     /* Hardware string instructions */
    STR_SIMD_AVX2,      /* 32-byte comparison */
    STR_SIMD_AVX512,    /* 64-byte comparison */
    STR_SIMD_NEON       /* ARM 16-byte comparison */
} str_simd_level_t;

/* Get optimal SIMD level for string operations */
str_simd_level_t str_get_simd_level(void);

/* Get human-readable SIMD level name */
const char* str_simd_level_name(str_simd_level_t level);

/* === Core String Comparison ===
 * 
 * Fast string equality check using SIMD.
 * Returns: true if strings are byte-for-byte equal, false otherwise.
 * 
 * Thread-safe: Yes (read-only operations)
 * Memory: No allocations
 */

/* Compare two null-terminated strings for equality
 * Auto-dispatches to best SIMD implementation
 * Returns: true if equal, false otherwise
 */
bool simd_str_equal(const char* a, const char* b);

/* Compare two length-prefixed strings for equality
 * More efficient - no strlen() call required
 * Returns: true if equal (including length), false otherwise
 */
bool simd_str_equal_len(const char* a, size_t len_a, const char* b, size_t len_b);

/* === Prefix/Suffix Matching ===
 * 
 * Optimized for path hierarchy checks (e.g., "/usr/lib".startsWith("/usr"))
 */

/* Check if string starts with prefix
 * Returns: true if a starts with prefix, false otherwise
 */
bool simd_str_starts_with(const char* str, size_t str_len,
                          const char* prefix, size_t prefix_len);

/* Check if string ends with suffix
 * Returns: true if str ends with suffix, false otherwise
 */
bool simd_str_ends_with(const char* str, size_t str_len,
                        const char* suffix, size_t suffix_len);

/* === Batch Operations ===
 * 
 * Compare multiple strings simultaneously - ideal for dependency lookups.
 * Uses SIMD parallelism across multiple comparisons.
 */

/* Find first matching string in array
 * Returns: Index of first match, or (size_t)-1 if not found
 */
size_t simd_str_find_first(const char* needle, size_t needle_len,
                           const char* const* haystack, size_t haystack_count);

/* Count matches in string array
 * Returns: Number of strings that equal needle
 */
size_t simd_str_count_matches(const char* needle, size_t needle_len,
                              const char* const* strings, size_t count);

/* Batch equality check: compare one string against multiple
 * Results: Output array where results[i] = (needle == strings[i])
 * Returns: Number of matches found
 */
size_t simd_str_batch_equal(const char* needle, size_t needle_len,
                            const char* const* strings, const size_t* lengths,
                            size_t count, bool* results);

/* === Path-Specific Operations ===
 * 
 * Optimized for file path comparisons with common patterns.
 */

/* Compare paths with normalization awareness
 * Handles trailing slashes and . components
 * Returns: true if paths refer to same location
 */
bool simd_path_equal(const char* a, size_t len_a, const char* b, size_t len_b);

/* Find common prefix length between two paths
 * Useful for computing relative paths
 * Returns: Length of common prefix (in bytes, up to directory boundary)
 */
size_t simd_path_common_prefix(const char* a, size_t len_a,
                               const char* b, size_t len_b);

/* === Hash-Aware Operations ===
 * 
 * For interning strings or cache lookups where we have precomputed hashes.
 * Skip SIMD comparison if hash mismatch (early exit).
 */

/* Compare with hash pre-check
 * If hash_a != hash_b, returns false immediately without comparing bytes
 * Returns: true if equal, false if hash mismatch or content differs
 */
bool simd_str_equal_with_hash(const char* a, size_t len_a, uint64_t hash_a,
                              const char* b, size_t len_b, uint64_t hash_b);

/* === Constant-Time Comparison ===
 * 
 * For security-sensitive string comparisons (tokens, keys).
 * Prevents timing attacks by always processing all bytes.
 */

/* Constant-time string comparison
 * Never short-circuits - always processes all bytes
 * Returns: true if equal, false otherwise
 */
bool simd_str_constant_time_equal(const char* a, size_t len_a,
                                  const char* b, size_t len_b);

#ifdef __cplusplus
}
#endif

#endif /* BUILDER_SIMD_STRINGS_H */

