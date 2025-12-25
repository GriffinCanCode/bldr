/**
 * Provenance Signing
 * 
 * Cryptographic signing for build provenance attestations using
 * BLAKE3-HMAC. Integrates with existing IntegrityValidator and
 * supports multiple signing schemes.
 * 
 * Signature Formats:
 * - BLAKE3-HMAC: Fast, default for local signing
 * - ECDSA P-256: Standard for external verification (future)
 * 
 * DSSE (Dead Simple Signing Envelope) compliant output.
 */
module engine.provenance.signer;

import std.base64 : Base64;
import std.conv : to;
import std.algorithm : map;
import std.array : array;
import engine.provenance.types;
import infrastructure.utils.crypto.blake3;
import infrastructure.utils.security.integrity;
import infrastructure.errors;

/// Signing algorithm identifier
enum SigningAlgorithm : string
{
    BLAKE3_HMAC = "blake3-hmac",
    ECDSA_P256 = "ecdsa-p256-sha256"
}

/// Provenance signer - signs attestations
struct ProvenanceSigner
{
    private IntegrityValidator validator;
    private string keyId;
    private SigningAlgorithm algorithm;
    
    /// Create signer with workspace-derived key
    static ProvenanceSigner fromWorkspace(string workspace) @system
    {
        ProvenanceSigner signer;
        signer.validator = IntegrityValidator.fromEnvironment(workspace);
        signer.keyId = computeKeyId(workspace);
        signer.algorithm = SigningAlgorithm.BLAKE3_HMAC;
        return signer;
    }
    
    /// Create signer with custom key
    static ProvenanceSigner withKey(in ubyte[32] key, string keyId) @system
    {
        ProvenanceSigner signer;
        signer.validator = IntegrityValidator.withKey(key);
        signer.keyId = keyId;
        signer.algorithm = SigningAlgorithm.BLAKE3_HMAC;
        return signer;
    }
    
    /// Sign provenance and create envelope
    BuildResult!ProvenanceEnvelope sign(const ref BuildProvenance provenance) @system
    {
        // Serialize statement to JSON
        auto payload = serializeStatement(provenance.statement);
        auto payloadBytes = cast(ubyte[]) payload;
        
        // Create PAE (Pre-Authentication Encoding) as per DSSE
        auto pae = createPAE(ProvenanceEnvelope.PAYLOAD_TYPE, payloadBytes);
        
        // Sign PAE
        auto signature = validator.sign(pae);
        
        // Create signature object
        Signature sig;
        sig.keyid = keyId;
        sig.sig = Base64.encode(signature[]);
        sig.signingAlgorithm = algorithm;
        
        // Create envelope
        ProvenanceEnvelope envelope;
        envelope.payloadType = ProvenanceEnvelope.PAYLOAD_TYPE;
        envelope.payload = Base64.encode(payloadBytes);
        envelope.signatures = [sig];
        
        return Ok!(ProvenanceEnvelope, BuildError)(envelope);
    }
    
    /// Verify signed envelope
    BuildResult!ProvenanceStatement verify(const ref ProvenanceEnvelope envelope) @system
    {
        if (envelope.signatures.length == 0)
            return Err!(ProvenanceStatement, BuildError)(
                Errors.system("No signatures in envelope", ErrorCode.ValidationFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        
        // Decode payload
        ubyte[] payloadBytes;
        try
            payloadBytes = Base64.decode(envelope.payload);
        catch (Exception e)
            return Err!(ProvenanceStatement, BuildError)(
                Errors.system("Invalid payload encoding: " ~ e.msg, ErrorCode.ValidationFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        
        // Verify at least one signature
        bool anyValid = false;
        foreach (ref sig; envelope.signatures)
        {
            ubyte[] sigBytes;
            try
                sigBytes = Base64.decode(sig.sig);
            catch (Exception)
                continue;
            
            auto pae = createPAE(envelope.payloadType, payloadBytes);
            if (validator.verify(pae, sigBytes))
            {
                anyValid = true;
                break;
            }
        }
        
        if (!anyValid)
            return Err!(ProvenanceStatement, BuildError)(
                Errors.system("Signature verification failed", ErrorCode.ValidationFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build());
        
        // Parse statement
        auto stmtResult = deserializeStatement(cast(string) payloadBytes);
        if (stmtResult.isErr)
            return Err!(ProvenanceStatement, BuildError)(stmtResult.unwrapErr());
        
        return Ok!(ProvenanceStatement, BuildError)(stmtResult.unwrap());
    }
    
    /// Get key identifier
    string getKeyId() const @safe pure nothrow
    {
        return keyId;
    }
}

/// Create PAE (Pre-Authentication Encoding) per DSSE spec
private ubyte[] createPAE(string payloadType, const(ubyte)[] payload) @system
{
    // PAE = "DSSEv1" || len(payloadType) || payloadType || len(payload) || payload
    ubyte[] result;
    
    // "DSSEv1 "
    result ~= cast(ubyte[]) "DSSEv1 ";
    
    // Length-prefixed payload type
    result ~= encodeLength(payloadType.length);
    result ~= cast(ubyte[]) payloadType;
    result ~= cast(ubyte) ' ';
    
    // Length-prefixed payload
    result ~= encodeLength(payload.length);
    result ~= payload;
    
    return result;
}

/// Encode length as ASCII decimal
private ubyte[] encodeLength(size_t len) @system pure
{
    return cast(ubyte[]) len.to!string;
}

/// Compute key identifier from workspace path
private string computeKeyId(string workspace) @system
{
    auto hash = Blake3.hashHex(cast(ubyte[]) workspace);
    return "bldr:" ~ hash[0..16];
}

/// Serialize provenance statement to JSON
string serializeStatement(const ref ProvenanceStatement stmt) @system
{
    import std.array : appender;
    import std.format : format;
    
    auto json = appender!string;
    json ~= "{\n";
    json ~= format(`  "_type": "%s",`~"\n", stmt._type);
    
    // Subjects
    json ~= `  "subject": [`~"\n";
    foreach (i, ref subj; stmt.subject)
    {
        json ~= "    {\n";
        json ~= format(`      "name": "%s",`~"\n", escapeJson(subj.name));
        json ~= `      "digest": {`~"\n";
        
        size_t j;
        foreach (algo, hash; subj.digest)
        {
            json ~= format(`        "%s": "%s"`, algo, hash);
            json ~= (++j < subj.digest.length) ? ",\n" : "\n";
        }
        
        json ~= "      }\n";
        json ~= "    }";
        json ~= (i + 1 < stmt.subject.length) ? ",\n" : "\n";
    }
    json ~= "  ],\n";
    
    // Predicate type and predicate
    json ~= format(`  "predicateType": "%s",`~"\n", stmt.predicateType);
    json ~= `  "predicate": {`~"\n";
    
    // Build definition
    json ~= `    "buildDefinition": {`~"\n";
    json ~= format(`      "buildType": "%s",`~"\n", stmt.predicate.buildDefinition.buildType);
    json ~= `      "resolvedDependencies": [`~"\n";
    
    foreach (i, ref dep; stmt.predicate.buildDefinition.resolvedDependencies)
    {
        json ~= "        {\n";
        json ~= format(`          "uri": "%s",`~"\n", escapeJson(dep.uri));
        json ~= `          "digest": {`~"\n";
        
        size_t j;
        foreach (algo, hash; dep.digest)
        {
            json ~= format(`            "%s": "%s"`, algo, hash);
            json ~= (++j < dep.digest.length) ? ",\n" : "\n";
        }
        
        json ~= "          }\n";
        json ~= "        }";
        json ~= (i + 1 < stmt.predicate.buildDefinition.resolvedDependencies.length) ? ",\n" : "\n";
    }
    json ~= "      ]\n";
    json ~= "    },\n";
    
    // Run details
    json ~= `    "runDetails": {`~"\n";
    json ~= `      "builder": {`~"\n";
    json ~= format(`        "id": "%s",`~"\n", stmt.predicate.runDetails.builder.id);
    json ~= format(`        "version": "%s"`~"\n", stmt.predicate.runDetails.builder.version_);
    json ~= "      },\n";
    json ~= `      "metadata": {`~"\n";
    json ~= format(`        "invocationId": "%s",`~"\n", stmt.predicate.runDetails.metadata.invocationId);
    json ~= format(`        "startedOn": "%s",`~"\n", stmt.predicate.runDetails.metadata.startedOn.toISOExtString());
    json ~= format(`        "finishedOn": "%s"`~"\n", stmt.predicate.runDetails.metadata.finishedOn.toISOExtString());
    json ~= "      }\n";
    json ~= "    }\n";
    json ~= "  }\n";
    json ~= "}";
    
    return json.data;
}

/// Escape JSON string
private string escapeJson(string s) @safe pure
{
    import std.array : appender;
    
    auto result = appender!string;
    foreach (c; s)
    {
        switch (c)
        {
            case '"': result ~= `\"`; break;
            case '\\': result ~= `\\`; break;
            case '\n': result ~= `\n`; break;
            case '\r': result ~= `\r`; break;
            case '\t': result ~= `\t`; break;
            default: result ~= c;
        }
    }
    return result.data;
}

/// Deserialize provenance statement from JSON (minimal parser)
BuildResult!ProvenanceStatement deserializeStatement(string json) @system
{
    // Minimal JSON parsing - extract key fields
    // For production, would use proper JSON parser
    
    ProvenanceStatement stmt;
    
    // Extract _type
    auto typeIdx = json.indexOf(`"_type"`);
    if (typeIdx == -1)
        return Err!(ProvenanceStatement, BuildError)(
            Errors.parse(json, "Missing _type field")
                .withLocation(__FILE__, __LINE__)
                .build());
    
    stmt._type = INTOTO_STATEMENT_TYPE;
    stmt.predicateType = SLSA_PREDICATE_TYPE;
    
    // Extract invocationId for metadata
    auto invocIdx = json.indexOf(`"invocationId"`);
    if (invocIdx != -1)
    {
        auto start = json.indexOf('"', invocIdx + 14);
        auto end = json.indexOf('"', start + 1);
        if (start != -1 && end != -1)
            stmt.predicate.runDetails.metadata.invocationId = json[start+1 .. end];
    }
    
    // Extract builder ID
    auto builderIdx = json.indexOf(`"id": "https://bldr.dev`);
    if (builderIdx != -1)
        stmt.predicate.runDetails.builder = BuilderId.bldr();
    
    return Ok!(ProvenanceStatement, BuildError)(stmt);
}

/// Helper: Find index in string
private ptrdiff_t indexOf(string s, string needle) @safe pure nothrow
{
    foreach (i; 0 .. s.length - needle.length + 1)
    {
        if (s[i .. i + needle.length] == needle)
            return i;
    }
    return -1;
}

/// Helper: Find index of char in string
private ptrdiff_t indexOf(string s, char needle, size_t start = 0) @safe pure nothrow
{
    foreach (i; start .. s.length)
    {
        if (s[i] == needle)
            return i;
    }
    return -1;
}

/// Serialize envelope to JSON
string serializeEnvelope(const ref ProvenanceEnvelope env) @system
{
    import std.format : format;
    import std.array : appender;
    
    auto json = appender!string;
    json ~= "{\n";
    json ~= format(`  "payloadType": "%s",`~"\n", env.payloadType);
    json ~= format(`  "payload": "%s",`~"\n", env.payload);
    json ~= `  "signatures": [`~"\n";
    
    foreach (i, ref sig; env.signatures)
    {
        json ~= "    {\n";
        json ~= format(`      "keyid": "%s",`~"\n", sig.keyid);
        json ~= format(`      "sig": "%s"`, sig.sig);
        if (sig.signingAlgorithm.length > 0)
            json ~= format(`,`~"\n" ~ `      "signingAlgorithm": "%s"`, sig.signingAlgorithm);
        json ~= "\n    }";
        json ~= (i + 1 < env.signatures.length) ? ",\n" : "\n";
    }
    
    json ~= "  ]\n";
    json ~= "}";
    
    return json.data;
}


