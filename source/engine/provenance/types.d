/**
 * SLSA Build Provenance Types
 * 
 * Implements SLSA v1.0 compliant provenance attestation format for
 * software supply chain security. These types form the foundation
 * for cryptographically signed build provenance.
 * 
 * SLSA Levels Supported:
 * - Level 1: Provenance exists (automatic)
 * - Level 2: Hosted build platform (with remote execution)
 * - Level 3: Hardened builds (hermetic mode)
 * 
 * Spec: https://slsa.dev/spec/v1.0/provenance
 */
module engine.provenance.types;

import std.datetime : SysTime, Clock;
import std.conv : to;
import std.algorithm : map;
import std.array : array;

/// SLSA predicate type for build provenance
enum SLSA_PREDICATE_TYPE = "https://slsa.dev/provenance/v1";

/// In-toto statement type
enum INTOTO_STATEMENT_TYPE = "https://in-toto.io/Statement/v1";

/// Digest algorithm identifiers
enum DigestAlgorithm : string
{
    BLAKE3 = "blake3",
    SHA256 = "sha256",
    SHA512 = "sha512"
}

/// Resource descriptor - identifies an artifact
struct ResourceDescriptor
{
    string uri;                              // Canonical URI
    string[string] digest;                   // Algorithm → hash
    string name;                             // Display name
    string downloadLocation;                 // Where to fetch
    string mediaType;                        // MIME type
    string[string] annotations;              // Extra metadata
    
    /// Create from file with hash
    static ResourceDescriptor fromFile(string path, string hash, DigestAlgorithm algo = DigestAlgorithm.BLAKE3)
    {
        ResourceDescriptor rd;
        rd.uri = "file://" ~ path;
        rd.digest[algo] = hash;
        rd.name = path;
        return rd;
    }
    
    /// Create from URI with digest
    static ResourceDescriptor fromUri(string uri, string hash, DigestAlgorithm algo = DigestAlgorithm.BLAKE3)
    {
        ResourceDescriptor rd;
        rd.uri = uri;
        rd.digest[algo] = hash;
        return rd;
    }
}

/// Build metadata - when/how/where
struct BuildMetadata
{
    string invocationId;          // Unique build invocation ID
    SysTime startedOn;            // Build start time
    SysTime finishedOn;           // Build end time
    
    /// Duration in milliseconds
    long durationMs() const @safe pure nothrow
    {
        auto dur = finishedOn - startedOn;
        return dur.total!"msecs";
    }
}

/// Builder identity - who performed the build
struct BuilderId
{
    string id;                    // Builder identity URI
    string version_;              // Builder version
    string[string] builderDependencies;  // Builder's own deps
    
    /// Create default bldr builder ID
    static BuilderId bldr(string version_ = "")
    {
        BuilderId b;
        b.id = "https://bldr.dev/builder/v1";
        b.version_ = version_.length > 0 ? version_ : "unknown";
        return b;
    }
}

/// Run details - execution specifics
struct RunDetails
{
    BuilderId builder;
    BuildMetadata metadata;
    ResourceDescriptor[] byproducts;  // Logs, intermediate artifacts
}

/// Build definition - what was built
struct BuildDefinition
{
    string buildType;                   // Build type URI
    ResourceDescriptor externalParameters;  // User-provided params
    ResourceDescriptor[] resolvedDependencies;  // Locked deps
    string[string] internalParameters;  // Builder-controlled params
}

/// SLSA Provenance Predicate (v1.0)
struct ProvenancePredicate
{
    BuildDefinition buildDefinition;
    RunDetails runDetails;
}

/// In-toto Statement with SLSA Provenance
struct ProvenanceStatement
{
    string _type = INTOTO_STATEMENT_TYPE;
    ResourceDescriptor[] subject;       // What was produced
    string predicateType = SLSA_PREDICATE_TYPE;
    ProvenancePredicate predicate;
}

/// Build provenance level (SLSA compliance)
enum SLSALevel : ubyte
{
    L0 = 0,  // No provenance
    L1 = 1,  // Provenance exists
    L2 = 2,  // Hosted build platform
    L3 = 3,  // Hardened builds
    L4 = 4   // Full verification (reserved)
}

/// Signed provenance envelope (DSSE format)
struct ProvenanceEnvelope
{
    string payloadType;           // application/vnd.in-toto+json
    string payload;               // Base64-encoded statement
    Signature[] signatures;
    
    /// DSSE envelope type
    static immutable PAYLOAD_TYPE = "application/vnd.in-toto+json";
}

/// Cryptographic signature
struct Signature
{
    string keyid;                 // Key identifier
    string sig;                   // Base64-encoded signature
    string signingAlgorithm;      // e.g., "blake3-hmac", "ecdsa-p256"
}

/// Build provenance attestation - complete record
struct BuildProvenance
{
    ProvenanceStatement statement;
    SLSALevel level;
    string attestationId;         // Unique attestation ID
    ubyte[32] provenanceHash;     // BLAKE3 hash of statement
    
    /// Check if provenance meets minimum SLSA level
    bool meetsLevel(SLSALevel required) const @safe pure nothrow
    {
        return level >= required;
    }
    
    /// Get human-readable level description
    string levelDescription() const @safe pure nothrow
    {
        final switch (level)
        {
            case SLSALevel.L0: return "No provenance";
            case SLSALevel.L1: return "Provenance exists";
            case SLSALevel.L2: return "Hosted build platform";
            case SLSALevel.L3: return "Hardened builds";
            case SLSALevel.L4: return "Full verification";
        }
    }
}

/// Provenance configuration
struct ProvenanceConfig
{
    bool enabled = true;                   // Generate provenance
    bool signProvenance = true;            // Sign attestations
    SLSALevel targetLevel = SLSALevel.L1;  // Target compliance level
    bool includeByproducts = false;        // Include logs/intermediates
    bool includeEnvironment = false;       // Include env vars (L3 only)
    string buildType = "https://bldr.dev/buildtypes/build/v1";
    string signingKeyPath;                 // Path to signing key
    
    /// Create config from environment
    static ProvenanceConfig fromEnvironment() @system
    {
        import std.process : environment;
        
        ProvenanceConfig cfg;
        
        if (auto val = environment.get("BLDR_PROVENANCE_ENABLED"))
            cfg.enabled = val == "true" || val == "1";
        
        if (auto val = environment.get("BLDR_PROVENANCE_SIGN"))
            cfg.signProvenance = val == "true" || val == "1";
        
        if (auto val = environment.get("BLDR_SLSA_LEVEL"))
        {
            try { cfg.targetLevel = val.to!SLSALevel; }
            catch (Exception) {}
        }
        
        if (auto val = environment.get("BLDR_SIGNING_KEY"))
            cfg.signingKeyPath = val;
        
        return cfg;
    }
    
    /// Hermetic (SLSA L3) configuration
    static ProvenanceConfig hermetic()
    {
        ProvenanceConfig cfg;
        cfg.targetLevel = SLSALevel.L3;
        cfg.includeByproducts = true;
        cfg.includeEnvironment = true;
        return cfg;
    }
}

/// Verification result for provenance
struct ProvenanceVerification
{
    bool valid;                    // Overall validity
    bool signatureValid;           // Signature verification passed
    bool hashMatch;                // Content hash matches
    bool levelMet;                 // Meets required SLSA level
    string[] violations;           // List of violations
    SLSALevel actualLevel;         // Actual SLSA level achieved
    
    /// Check if verification passed
    bool passed() const @safe pure nothrow
    {
        return valid && signatureValid && hashMatch;
    }
}


