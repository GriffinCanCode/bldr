module engine.distributed.protocol.reapi_v2.hash;

import std.digest : toHexString;
import std.string : toLower;
import std.conv : to;
import engine.distributed.protocol.protocol : ActionId;
import engine.distributed.protocol.reapi_v2.types;
import infrastructure.errors;

/// Hash format enumeration
enum HashFormat {
    BLAKE3_32,    // Builder's native (32 bytes)
    SHA256,       // REAPI standard (32 bytes)
    SHA1,         // Legacy (20 bytes)
    MD5           // Legacy (16 bytes)
}

/// Bidirectional hash translation between Builder (BLAKE3) and REAPI (SHA256/etc.)
/// 
/// Strategy: Since cryptographic hashes cannot be directly converted,
/// we maintain a translation table that maps content hashes bidirectionally.
/// For new content, we compute both hashes during ingestion.
final class HashTranslator {
    private ubyte[32][ubyte[32]] blake3ToSha256;  // BLAKE3 → SHA256
    private ubyte[32][ubyte[32]] sha256ToBlake3;  // SHA256 → BLAKE3
    private HashFormat defaultFormat = HashFormat.SHA256;
    
    this(HashFormat defaultFormat = HashFormat.SHA256) @safe {
        this.defaultFormat = defaultFormat;
    }
    
    /// Register a hash pair (both hashes for same content)
    void registerPair(const ubyte[32] blake3Hash, const ubyte[32] sha256Hash) @trusted {
        blake3ToSha256[blake3Hash] = sha256Hash;
        sha256ToBlake3[sha256Hash] = blake3Hash;
    }
    
    /// Convert ActionId to ReapiDigest
    Result!(ReapiDigest, string) actionIdToDigest(ActionId actionId, long sizeBytes) const @trusted {
        if (actionId.hash in blake3ToSha256) {
            auto sha256 = blake3ToSha256[actionId.hash];
            return Ok!(ReapiDigest, string)(
                ReapiDigest(sha256[], sizeBytes, DigestFunction.SHA256));
        }
        
        // Fallback: expose BLAKE3 directly if no translation exists
        // Some REAPI servers support BLAKE3 natively
        return Ok!(ReapiDigest, string)(
            ReapiDigest(actionId.hash[], sizeBytes, DigestFunction.BLAKE3));
    }
    
    /// Convert ReapiDigest to ActionId
    Result!(ActionId, string) digestToActionId(ReapiDigest digest) const @trusted {
        if (digest.func == DigestFunction.BLAKE3 && digest.hash.length == 32) {
            ubyte[32] hash;
            hash[] = digest.hash[0 .. 32];
            return Ok!(ActionId, string)(ActionId(hash));
        }
        
        if (digest.func == DigestFunction.SHA256 && digest.hash.length == 32) {
            ubyte[32] sha256;
            sha256[] = digest.hash[0 .. 32];
            
            if (sha256 in sha256ToBlake3) {
                return Ok!(ActionId, string)(ActionId(sha256ToBlake3[sha256]));
            }
            
            return Err!(ActionId, string)(
                "Unknown SHA256 hash - not in translation table");
        }
        
        return Err!(ActionId, string)(
            "Unsupported digest function: " ~ digest.func.to!string);
    }
    
    /// Compute both hashes for content and register pair
    void registerContent(const ubyte[] content) @trusted {
        import infrastructure.utils.crypto.blake3 : Blake3;
        import std.digest.sha : SHA256;
        
        // Compute BLAKE3
        auto blake3 = Blake3(0);
        blake3.put(content);
        auto blake3Result = blake3.finish(32);
        ubyte[32] blake3Hash;
        blake3Hash[] = blake3Result[0 .. 32];
        
        // Compute SHA256
        ubyte[32] sha256Hash = SHA256.digest(content);
        
        registerPair(blake3Hash, sha256Hash);
    }
    
    /// Check if hash exists in translation table
    bool hasBlake3(const ubyte[32] hash) const @trusted =>
        (hash in blake3ToSha256) !is null;
    
    bool hasSha256(const ubyte[32] hash) const @trusted =>
        (hash in sha256ToBlake3) !is null;
    
    /// Get default digest function
    DigestFunction getDefaultFunction() const pure nothrow @safe @nogc {
        final switch (defaultFormat) {
            case HashFormat.BLAKE3_32: return DigestFunction.BLAKE3;
            case HashFormat.SHA256: return DigestFunction.SHA256;
            case HashFormat.SHA1: return DigestFunction.SHA1;
            case HashFormat.MD5: return DigestFunction.MD5;
        }
    }
    
    /// Get hash byte length for function
    static size_t hashLength(DigestFunction func) pure nothrow @safe @nogc {
        final switch (func) {
            case DigestFunction.Unknown: return 0;
            case DigestFunction.SHA256: return 32;
            case DigestFunction.SHA1: return 20;
            case DigestFunction.MD5: return 16;
            case DigestFunction.VSO: return 32;
            case DigestFunction.SHA384: return 48;
            case DigestFunction.SHA512: return 64;
            case DigestFunction.MURMUR3: return 16;
            case DigestFunction.SHA256TREE: return 32;
            case DigestFunction.BLAKE3: return 32;
        }
    }
}

/// Compute BLAKE3 hash of data
ubyte[32] computeBlake3(const ubyte[] data) @trusted {
    import infrastructure.utils.crypto.blake3 : Blake3;
    
    auto hasher = Blake3(0);
    hasher.put(data);
    auto result = hasher.finish(32);
    
    ubyte[32] hash;
    hash[] = result[0 .. 32];
    return hash;
}

/// Compute SHA256 hash of data
ubyte[32] computeSha256(const ubyte[] data) @trusted {
    import std.digest.sha : SHA256;
    return SHA256.digest(data);
}

/// Create ReapiDigest from content with specified function
ReapiDigest digestContent(const ubyte[] data, DigestFunction func = DigestFunction.SHA256) @trusted {
    final switch (func) {
        case DigestFunction.SHA256:
            return ReapiDigest(computeSha256(data)[], data.length, func);
        case DigestFunction.BLAKE3:
            return ReapiDigest(computeBlake3(data)[], data.length, func);
        case DigestFunction.Unknown:
        case DigestFunction.SHA1:
        case DigestFunction.MD5:
        case DigestFunction.VSO:
        case DigestFunction.SHA384:
        case DigestFunction.SHA512:
        case DigestFunction.MURMUR3:
        case DigestFunction.SHA256TREE:
            // Unsupported - fallback to SHA256
            return ReapiDigest(computeSha256(data)[], data.length, DigestFunction.SHA256);
    }
}

