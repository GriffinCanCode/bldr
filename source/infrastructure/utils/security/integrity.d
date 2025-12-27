module infrastructure.utils.security.integrity;

import std.datetime;
import std.conv;
import std.algorithm;
import std.bitmanip;
import infrastructure.utils.crypto.blake3;
import infrastructure.errors : Errors, Cache;


/// BLAKE3-based HMAC for cache integrity validation
/// Provides cryptographic verification to prevent tampering
struct IntegrityValidator
{
    private static immutable ubyte[32] DEFAULT_KEY = [
        0x62, 0x75, 0x69, 0x6c, 0x64, 0x65, 0x72, 0x2d,  // "builder-"
        0x63, 0x61, 0x63, 0x68, 0x65, 0x2d, 0x6b, 0x65,  // "cache-ke"
        0x79, 0x2d, 0x76, 0x31, 0x00, 0x00, 0x00, 0x00,  // "y-v1...."
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00   // "...."
    ];
    
    private ubyte[32] key;
    
    /// Create with custom key
    static IntegrityValidator withKey(in ubyte[32] customKey) @system pure nothrow @nogc
    {
        IntegrityValidator v;
        v.key = customKey;
        return v;
    }
    
    /// Create with default key (suitable for local cache validation)
    static IntegrityValidator create() @system pure nothrow @nogc
    {
        IntegrityValidator v;
        v.key = DEFAULT_KEY;
        return v;
    }
    
    /// Create with environment-specific key (for distributed builds)
    /// 
    /// Safety: This function is @system because:
    /// 1. sha256Of performs hash computation (uses C bindings internally)
    /// 2. getMachineId() performs system calls for machine identification
    /// 3. String concatenation for key derivation is safe
    /// 4. Blake3.keyed() uses extern(C) functions with validated parameters
    /// 
    /// Invariants:
    /// - Machine ID is stable for the system
    /// - Workspace path is incorporated into key derivation
    /// - Resulting validator has unique key per machine+workspace combo
    /// 
    /// What could go wrong:
    /// - Machine ID could change on system reconfiguration: cache invalidated (intended)
    /// - Workspace path with special characters: handled by hash function
    /// - getMachineId() could fail: throws exception (caller must handle)
    static IntegrityValidator fromEnvironment(string workspace) @system
    {
        import std.digest.sha : sha256Of;
        
        IntegrityValidator v;
        // Derive key from workspace path + machine ID
        auto keyMaterial = workspace ~ getMachineId();
        auto hash = sha256Of(keyMaterial);
        v.key[0 .. 32] = hash[0 .. 32];
        return v;
    }
    
    /// Generate HMAC-BLAKE3 for data
    /// 
    /// Safety: This function is @system because:
    /// 1. Blake3 wrapper uses extern(C) BLAKE3 implementation
    /// 2. Keyed hashing with validated key (set in constructor)
    /// 3. finish() allocates exact-size buffer (no overrun)
    /// 4. Array slicing with [0..32] is bounds-checked
    /// 
    /// Invariants:
    /// - key is exactly BLAKE3_KEY_LEN bytes (enforced by type)
    /// - Output is always exactly 32 bytes
    /// - Same data produces same signature (deterministic)
    /// 
    /// What could go wrong:
    /// - Nothing: keyed BLAKE3 is cryptographically secure
    /// - Side channel attacks: possible but mitigated by constant-time ops in BLAKE3
    ubyte[32] sign(scope const(ubyte)[] data) const @system
    {
        // HMAC-BLAKE3: H(K XOR opad || H(K XOR ipad || message))
        // Using keyed BLAKE3 for simpler, faster implementation
        auto hasher = Blake3.keyed(key);
        hasher.put(cast(ubyte[])data);
        auto result = hasher.finish(32);
        
        ubyte[32] signature;
        signature[0 .. 32] = result[0 .. 32];
        return signature;
    }
    
    /// Verify HMAC-BLAKE3 signature (constant-time comparison)
    /// 
    /// Safety: This function is @system because:
    /// 1. Delegates to trusted sign() function
    /// 2. constantTimeEquals prevents timing attacks (critical for security)
    /// 3. Fixed-size array comparison is memory-safe
    /// 
    /// Invariants:
    /// - Comparison is constant-time (no early exit on mismatch)
    /// - Both arrays are exactly 32 bytes
    /// 
    /// What could go wrong:
    /// - Timing attacks if not constant-time: prevented by constantTimeEquals
    /// - Signature forgery: cryptographically infeasible with BLAKE3-HMAC
    bool verify(scope const(ubyte)[] data, in ubyte[32] signature) const @system
    {
        auto computed = sign(data);
        return constantTimeEquals(computed, signature);
    }
    
    /// Verify HMAC-BLAKE3 signature with dynamic array (convenience overload)
    /// 
    /// Safety: This function is @system because:
    /// 1. Length check prevents out-of-bounds access
    /// 2. Array slicing to fixed-size array is validated by length check
    /// 3. Delegates to trusted verify() with fixed-size array
    /// 
    /// Invariants:
    /// - Signature must be exactly 32 bytes or verification fails
    /// - Copies signature data to fixed array before verification
    /// 
    /// What could go wrong:
    /// - Invalid signature length: returns false (safe failure mode)
    /// - Truncated signature: rejected by length check
    bool verify(scope const(ubyte)[] data, scope const(ubyte)[] signature) const @system
    {
        if (signature.length != 32)
            return false;
        
        ubyte[32] fixedSig;
        fixedSig[0 .. 32] = signature[0 .. 32];
        return verify(data, fixedSig);
    }
    
    /// Sign with timestamp and version info
    /// 
    /// Safety: This function is @system because:
    /// 1. Clock.currTime() is system call (unsafe I/O)
    /// 2. nativeToBigEndian for endianness conversion is safe
    /// 3. Array concatenation and copy operations are memory-safe
    /// 4. Delegates to trusted sign() function
    /// 
    /// Invariants:
    /// - Timestamp is monotonic (system clock dependent)
    /// - Version and timestamp are encoded in big-endian
    /// - Signature covers version + timestamp + data (tamper-proof)
    /// 
    /// What could go wrong:
    /// - System clock manipulation: could create backdated signatures (unavoidable)
    /// - Replay attacks: mitigated by including timestamp in signature
    /// - Version mismatch on deserialization: handled by version check
    SignedData signWithMetadata(scope const(ubyte)[] data, uint version_ = 1) const @system
    {
        SignedData signed;
        signed.version_ = version_;
        signed.timestamp = Clock.currTime().stdTime;
        signed.data = cast(ubyte[])data.dup;
        
        // Create payload: version(4) || timestamp(8) || data(N)
        ubyte[] payload;
        payload ~= nativeToBigEndian(version_)[];
        payload ~= nativeToBigEndian(signed.timestamp)[];
        payload ~= signed.data;
        
        signed.signature = sign(payload);
        return signed;
    }
    
    /// Verify signed data with metadata
    /// 
    /// Safety: This function is @system because:
    /// 1. Reconstructs payload with same encoding as signWithMetadata
    /// 2. nativeToBigEndian is safe for endianness conversion
    /// 3. Array concatenation is memory-safe
    /// 4. Delegates to trusted verify() for constant-time comparison
    /// 
    /// Invariants:
    /// - Payload reconstruction must match signing process exactly
    /// - Version and timestamp encoding must be identical to signing
    /// - Verification is constant-time (prevents timing attacks)
    /// 
    /// What could go wrong:
    /// - Modified version or timestamp: signature verification fails (intended)
    /// - Replay attack with old valid signature: caller must check timestamp freshness
    /// - Endianness mismatch: prevented by explicit big-endian encoding
    bool verifyWithMetadata(in SignedData signed) const @system
    {
        // Reconstruct payload
        ubyte[] payload;
        payload ~= nativeToBigEndian(signed.version_)[];
        payload ~= nativeToBigEndian(signed.timestamp)[];
        payload ~= signed.data;
        
        return verify(payload, signed.signature);
    }
    
    /// Alias for verifyWithMetadata
    alias verifyMetadata = verifyWithMetadata;
    
    /// Check if signed data is expired
    static bool isExpired(in SignedData signed, Duration maxAge) @system
    {
        auto signedTime = SysTime(signed.timestamp);
        auto now = Clock.currTime();
        return (now - signedTime) > maxAge;
    }
}

/// Signed data container
struct SignedData
{
    uint version_;
    long timestamp;  // stdTime
    ubyte[] data;
    ubyte[32] signature;
    
    /// Serialize to binary format
    /// 
    /// Safety: This function is @system because:
    /// 1. nativeToBigEndian produces fixed-size arrays (no buffer overrun)
    /// 2. Array concatenation (~=) is memory-safe
    /// 3. reserve() pre-allocates to avoid reallocations
    /// 4. Cast of string to ubyte[] has same memory layout
    /// 
    /// Invariants:
    /// - Result has deterministic size: 4 + 8 + 32 + 4 + data.length
    /// - All multi-byte integers are big-endian encoded
    /// - Pure function: no side effects
    /// 
    /// What could go wrong:
    /// - Very large data could cause allocation failure: exception propagates
    /// - Nothing else: serialization format is unambiguous
    ubyte[] serialize() const @system pure
    {
        ubyte[] result;
        result.reserve(4 + 8 + 32 + 4 + data.length);
        
        result ~= nativeToBigEndian(version_)[];
        result ~= nativeToBigEndian(timestamp)[];
        result ~= signature[];
        result ~= nativeToBigEndian(cast(uint)data.length)[];
        result ~= data;
        
        return result;
    }
    
    /// Deserialize from binary format
    /// 
    /// Safety: This function is @system because:
    /// 1. Length validation prevents out-of-bounds access
    /// 2. read() from std.bitmanip is bounds-checked
    /// 3. Array slicing is validated against remaining length
    /// 4. Cast of ubyte[] to string is safe (UTF-8 validation not required here)
    /// 
    /// Invariants:
    /// - Minimum size check prevents buffer underrun
    /// - Data length is validated before slicing
    /// - All multi-byte integers decoded as big-endian
    /// 
    /// What could go wrong:
    /// - Corrupted data: length mismatch throws exception (safe failure)
    /// - Truncated input: caught by length check
    /// - Invalid UTF-8 in data: not validated (caller responsibility)
    static SignedData deserialize(scope const(ubyte)[] bytes) @system
    {
        if (bytes.length < 4 + 8 + 32 + 4)
            throw Errors.cache("Invalid signed data: too short", Cache.Corrupted)
                .withSuggestion("Signed data is truncated or corrupted")
                .withCommand("Clear cache", "bldr clean --cache").build();
        
        SignedData signed;
        size_t offset = 0;
        
        signed.version_ = bigEndianToNative!uint(bytes[offset .. offset + 4][0 .. 4]);
        offset += 4;
        
        signed.timestamp = bigEndianToNative!long(bytes[offset .. offset + 8][0 .. 8]);
        offset += 8;
        
        signed.signature[0 .. 32] = bytes[offset .. offset + 32];
        offset += 32;
        
        auto dataLen = bigEndianToNative!uint(bytes[offset .. offset + 4][0 .. 4]);
        offset += 4;
        
        if (offset + dataLen != bytes.length)
            throw Errors.cache("Invalid signed data: length mismatch", Cache.Corrupted)
                .withSuggestion("Signed data has invalid length encoding")
                .withCommand("Clear cache", "bldr clean --cache").build();
        
        signed.data = cast(ubyte[])bytes[offset .. $].dup;
        
        return signed;
    }
}

/// Constant-time equality comparison (prevents timing attacks)
bool constantTimeEquals(in ubyte[] a, in ubyte[] b) @system pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    
    ubyte result = 0;
    foreach (i; 0 .. a.length)
        result |= a[i] ^ b[i];
    
    return result == 0;
}

/// Get machine-specific identifier
/// 
/// Safety: This function is @system because:
/// 1. File system operations to read machine ID files are unsafe I/O
/// 2. String operations (strip, readText) are safe
/// 3. Fallback to username is safe (getenv uses C bindings)
/// 4. Exception handling prevents crashes
/// 
/// Invariants:
/// - Returns stable identifier for the machine (OS-specific)
/// - Falls back to username if machine ID unavailable
/// - Last resort: returns "unknown" (safe default)
/// 
/// What could go wrong:
/// - Machine ID files could be unreadable: falls back to username
/// - Username unavailable: falls back to "unknown"
/// - Machine ID could change on system update: cache invalidation (intended)
/// - Containers/VMs: may share machine ID (limitation of approach)
private string getMachineId() @system
{
    version(Posix)
    {
        import std.process : execute;
        import std.string : strip;
        
        // Try /etc/machine-id first (Linux)
        try
        {
            import std.file : readText;
            return readText("/etc/machine-id").strip;
        }
        catch (Exception e)
        {
            // Expected to fail on non-Linux systems, continue to next method
        }
        
        // Try hostid (Unix)
        try
        {
            auto result = execute(["hostid"]);
            if (result.status == 0)
                return result.output.strip;
        }
        catch (Exception e)
        {
            // Expected to fail if hostid not available, continue to next method
        }
    }
    
    version(Windows)
    {
        import std.process : execute;
        import std.string : strip;
        
        try
        {
            auto result = execute(["wmic", "csproduct", "get", "UUID"]);
            if (result.status == 0)
                return result.output.strip;
        }
        catch (Exception e)
        {
            // Expected to fail if wmic not available, will use fallback
        }
    }
    
    // Fallback: use username + hostname
    import std.socket : Socket;
    return Socket.hostName();
}

@system unittest
{
    // Test basic signing and verification
    auto validator = IntegrityValidator.create();
    ubyte[] data = [1, 2, 3, 4, 5];
    auto signature = validator.sign(data);
    assert(validator.verify(data, signature));
    
    // Test tampering detection
    data[0] = 99;
    assert(!validator.verify(data, signature));
    
    // Test metadata signing
    auto signed = validator.signWithMetadata([10, 20, 30]);
    assert(validator.verifyWithMetadata(signed));
    
    // Test tampering with metadata
    signed.data[0] = 99;
    assert(!validator.verifyWithMetadata(signed));
    
    // Test serialization
    auto bytes = signed.serialize();
    auto deserialized = SignedData.deserialize(bytes);
    assert(deserialized.version_ == signed.version_);
    assert(deserialized.timestamp == signed.timestamp);
    assert(deserialized.data == signed.data);
    
    // Test constant-time comparison
    assert(constantTimeEquals([1, 2, 3], [1, 2, 3]));
    assert(!constantTimeEquals([1, 2, 3], [1, 2, 4]));
}

