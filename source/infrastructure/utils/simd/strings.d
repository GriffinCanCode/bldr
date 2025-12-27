module infrastructure.utils.simd.strings;

/// SIMD-Accelerated String Comparison
/// 
/// Hardware-optimized string operations for dependency resolution and path matching.
/// Auto-dispatches to best SIMD implementation at runtime.
/// 
/// Performance:
///   - 4-8x faster for strings >= 32 bytes on AVX2
///   - 8-16x faster for strings >= 64 bytes on AVX-512
///   - 2-3x faster for strings >= 16 bytes on ARM NEON
///   - Negligible overhead for short strings (falls back to memcmp)
/// 
/// Use Cases:
///   - Path comparison in dependency resolution
///   - Target ID lookups in build graph
///   - Cache key validation
///   - Hermetic path checking
/// 
/// Example:
/// ```d
/// import infrastructure.utils.simd.strings;
/// 
/// // Fast string comparison
/// if (SIMDStrings.equal("/usr/lib/libfoo.so", candidatePath)) {
///     // Found match
/// }
/// 
/// // Prefix matching for path hierarchies
/// if (SIMDStrings.startsWith(path, "/workspace/src/")) {
///     // Path is under workspace
/// }
/// 
/// // Batch lookup in string arrays
/// auto idx = SIMDStrings.findFirst("main.d", sourceFiles);
/// 
/// // Security-sensitive comparison
/// if (SIMDStrings.constantTimeEqual(token, expectedToken)) {
///     // Timing-attack resistant
/// }
/// ```

extern(C) @system pure nothrow @nogc:

/// SIMD capability levels for string operations
enum StringSIMDLevel
{
    None,      /// Portable scalar
    SSE2,      /// 16-byte comparison
    SSE42,     /// Hardware string instructions
    AVX2,      /// 32-byte comparison
    AVX512,    /// 64-byte comparison
    NEON       /// ARM 16-byte comparison
}

/// Get optimal SIMD level for string operations
StringSIMDLevel str_get_simd_level();

/// Get human-readable SIMD level name
const(char)* str_simd_level_name(StringSIMDLevel level);

/* === Core C Bindings === */

bool simd_str_equal(const(char)* a, const(char)* b);
bool simd_str_equal_len(const(char)* a, size_t len_a, const(char)* b, size_t len_b);
bool simd_str_starts_with(const(char)* str, size_t str_len, const(char)* prefix, size_t prefix_len);
bool simd_str_ends_with(const(char)* str, size_t str_len, const(char)* suffix, size_t suffix_len);
size_t simd_str_find_first(const(char)* needle, size_t needle_len, const(char*)* haystack, size_t count);
size_t simd_str_count_matches(const(char)* needle, size_t needle_len, const(char*)* strings, size_t count);
size_t simd_str_batch_equal(const(char)* needle, size_t needle_len, const(char*)* strings, 
                            const(size_t)* lengths, size_t count, bool* results);
bool simd_path_equal(const(char)* a, size_t len_a, const(char)* b, size_t len_b);
size_t simd_path_common_prefix(const(char)* a, size_t len_a, const(char)* b, size_t len_b);
bool simd_str_equal_with_hash(const(char)* a, size_t len_a, ulong hash_a, 
                              const(char)* b, size_t len_b, ulong hash_b);
bool simd_str_constant_time_equal(const(char)* a, size_t len_a, const(char)* b, size_t len_b);

/// D-friendly wrapper for SIMD string operations
/// Thread-safe: All operations are read-only
struct SIMDStrings
{
    /// Get current SIMD capability level
    @property static StringSIMDLevel simdLevel() @safe pure nothrow @nogc
    {
        return (() @trusted => str_get_simd_level())();
    }
    
    /// Get human-readable SIMD level name
    @property static string simdLevelName() @trusted
    {
        import std.string : fromStringz;
        return cast(string) fromStringz(str_simd_level_name(str_get_simd_level()));
    }
    
    /// Compare two strings for equality using SIMD
    static bool equal(scope const(char)[] a, scope const(char)[] b) @system pure nothrow @nogc
    {
        if (a.length != b.length) return false;
        if (a.ptr is b.ptr) return true;
        if (a.length == 0) return true;
        return simd_str_equal_len(a.ptr, a.length, b.ptr, b.length);
    }
    
    /// Check if string starts with prefix
    static bool startsWith(scope const(char)[] str, scope const(char)[] prefix) @system pure nothrow @nogc
    {
        if (prefix.length > str.length) return false;
        if (prefix.length == 0) return true;
        return simd_str_starts_with(str.ptr, str.length, prefix.ptr, prefix.length);
    }
    
    /// Check if string ends with suffix
    static bool endsWith(scope const(char)[] str, scope const(char)[] suffix) @system pure nothrow @nogc
    {
        if (suffix.length > str.length) return false;
        if (suffix.length == 0) return true;
        return simd_str_ends_with(str.ptr, str.length, suffix.ptr, suffix.length);
    }
    
    /// Find first matching string in array
    /// Returns: Index of first match, or -1 if not found
    static ptrdiff_t findFirst(scope const(char)[] needle, scope const(char*)[] haystack) @system pure nothrow @nogc
    {
        if (haystack.length == 0) return -1;
        immutable result = simd_str_find_first(needle.ptr, needle.length, haystack.ptr, haystack.length);
        return result == cast(size_t)-1 ? -1 : cast(ptrdiff_t) result;
    }
    
    /// Find first matching string in array of D strings
    static ptrdiff_t findFirstD(scope const(char)[] needle, scope const(string)[] haystack) @system
    {
        import std.algorithm : map;
        import std.array : array;
        
        if (haystack.length == 0) return -1;
        
        auto ptrs = haystack.map!(s => s.ptr).array;
        immutable result = simd_str_find_first(needle.ptr, needle.length, ptrs.ptr, ptrs.length);
        return result == cast(size_t)-1 ? -1 : cast(ptrdiff_t) result;
    }
    
    /// Count matching strings in array
    static size_t countMatches(scope const(char)[] needle, scope const(char*)[] strings) @system pure nothrow @nogc
    {
        if (strings.length == 0) return 0;
        return simd_str_count_matches(needle.ptr, needle.length, strings.ptr, strings.length);
    }
    
    /// Compare paths with normalization (handles trailing slashes)
    static bool pathEqual(scope const(char)[] a, scope const(char)[] b) @system pure nothrow @nogc
    {
        return simd_path_equal(a.ptr, a.length, b.ptr, b.length);
    }
    
    /// Find common prefix length between two paths (up to directory boundary)
    static size_t pathCommonPrefix(scope const(char)[] a, scope const(char)[] b) @system pure nothrow @nogc
    {
        return simd_path_common_prefix(a.ptr, a.length, b.ptr, b.length);
    }
    
    /// Compare with precomputed hash (fast early-exit on hash mismatch)
    static bool equalWithHash(scope const(char)[] a, ulong hashA, 
                              scope const(char)[] b, ulong hashB) @system pure nothrow @nogc
    {
        return simd_str_equal_with_hash(a.ptr, a.length, hashA, b.ptr, b.length, hashB);
    }
    
    /// Constant-time comparison (timing-attack resistant)
    static bool constantTimeEqual(scope const(char)[] a, scope const(char)[] b) @system pure nothrow @nogc
    {
        return simd_str_constant_time_equal(a.ptr, a.length, b.ptr, b.length);
    }
    
    /// Batch equality check: compare needle against multiple strings
    @system
    static auto batchEqual(scope const(char)[] needle, 
                           scope const(char*)[] strings,
                           scope const(size_t)[] lengths)
    {
        struct BatchResult { bool[] results; size_t matchCount; }
        
        if (strings.length == 0)
            return BatchResult(null, 0);
        
        auto results = new bool[strings.length];
        auto lengthsPtr = lengths.length > 0 ? lengths.ptr : null;
        auto matches = simd_str_batch_equal(
            needle.ptr, needle.length,
            strings.ptr, lengthsPtr,
            strings.length, results.ptr
        );
        
        return BatchResult(results, matches);
    }
}

/// Check if SIMD string acceleration is active
bool hasSIMDStrings() @safe pure nothrow @nogc
{
    return (() @trusted => str_get_simd_level() != StringSIMDLevel.None)();
}

/// Unit tests
version(unittest):

@("SIMDStrings - basic equality")
@system unittest
{
    assert(SIMDStrings.equal("hello", "hello"));
    assert(!SIMDStrings.equal("hello", "world"));
    assert(!SIMDStrings.equal("hello", "hell"));
}

@("SIMDStrings - long string comparison")
@system unittest
{
    auto longStr1 = "this is a much longer string that exceeds 32 bytes for AVX2 testing purposes";
    auto longStr2 = "this is a much longer string that exceeds 32 bytes for AVX2 testing purposes";
    auto longStr3 = "this is a much longer string that exceeds 32 bytes for AVX2 testing DIFFERS";
    
    assert(SIMDStrings.equal(longStr1, longStr2));
    assert(!SIMDStrings.equal(longStr1, longStr3));
}

@("SIMDStrings - prefix/suffix matching")
@system unittest
{
    assert(SIMDStrings.startsWith("/usr/lib/libfoo.so", "/usr/lib"));
    assert(!SIMDStrings.startsWith("/usr/lib", "/usr/lib/"));
    assert(SIMDStrings.endsWith("/usr/lib/libfoo.so", ".so"));
    assert(!SIMDStrings.endsWith("/usr/lib/libfoo.so", ".a"));
}

@("SIMDStrings - path comparison")
@system unittest
{
    assert(SIMDStrings.pathEqual("/usr/lib/", "/usr/lib"));
    assert(SIMDStrings.pathEqual("/usr/lib", "/usr/lib/"));
    assert(!SIMDStrings.pathEqual("/usr/lib", "/usr/local"));
}

@("SIMDStrings - common prefix")
@system unittest
{
    auto prefix = SIMDStrings.pathCommonPrefix("/usr/lib/foo", "/usr/lib/bar");
    assert(prefix == 9, "Expected /usr/lib/ (9 chars)");
    
    prefix = SIMDStrings.pathCommonPrefix("/usr/local", "/usr/lib");
    assert(prefix == 5, "Expected /usr/ (5 chars)");
}

@("SIMDStrings - constant-time comparison")
@system unittest
{
    assert(SIMDStrings.constantTimeEqual("secret", "secret"));
    assert(!SIMDStrings.constantTimeEqual("secret", "DIFFER"));
    
    auto s1 = "a_very_long_secret_token_that_needs_constant_time_comparison_xyz";
    auto s2 = "a_very_long_secret_token_that_needs_constant_time_comparison_xyz";
    auto s3 = "a_very_long_secret_token_that_needs_constant_time_comparison_ABC";
    
    assert(SIMDStrings.constantTimeEqual(s1, s2));
    assert(!SIMDStrings.constantTimeEqual(s1, s3));
}

@("SIMDStrings - hash-based comparison")
@system unittest
{
    immutable ulong h1 = 0xDEADBEEF;
    immutable ulong h2 = 0xDEADBEEF;
    immutable ulong h3 = 0xCAFEBABE;
    
    assert(SIMDStrings.equalWithHash("test", h1, "test", h2));
    assert(!SIMDStrings.equalWithHash("test", h1, "test", h3));
}

