module infrastructure.repository.acquisition.verifier;

import std.file : read, exists;
import std.algorithm : equal;
import std.range : chunks;
import infrastructure.utils.crypto.blake3;
import infrastructure.repository.core.types;
import infrastructure.errors;

/// Integrity verifier for repository artifacts
struct IntegrityVerifier
{
    /// Verify file integrity using SHA256 or BLAKE3
    static Result!RepositoryError verify(string filePath, string expectedHash) @trusted
    {
        if (!exists(filePath))
            return Result!RepositoryError.err(
                new RepositoryError("File not found for verification: " ~ filePath));
        
        // Detect hash format (hex length indicates algorithm)
        immutable hashLen = expectedHash.length;
        
        // BLAKE3: 64 hex chars (32 bytes)
        // SHA256: 64 hex chars (32 bytes)
        // For now, we'll use BLAKE3 as it's already in the codebase
        if (hashLen == 64)
        {
            return verifyBlake3(filePath, expectedHash);
        }
        else
        {
            return Result!RepositoryError.err(
                new RepositoryError("Unsupported hash format (expected 64 hex characters)"));
        }
    }
    
    /// Verify using BLAKE3
    private static Result!RepositoryError verifyBlake3(string filePath, string expectedHash) @trusted
    {
        import std.string : toLower;
        import std.conv : to;
        
        try
        {
            // Read file and compute BLAKE3 hash
            auto data = cast(ubyte[])read(filePath);
            auto actualHex = Blake3.hashHex(data).toLower();
            auto expectedHex = expectedHash.toLower();
            
            if (actualHex != expectedHex)
            {
                auto error = new RepositoryError(
                    "Integrity check failed for " ~ filePath,
                    Repository.ContentVerificationFailed
                );
                error.addSuggestion("Expected: " ~ expectedHex);
                error.addSuggestion("Got:      " ~ actualHex);
                error.addSuggestion("The downloaded file may be corrupted or tampered with");
                return Result!RepositoryError.err(error);
            }
            
            return Ok!RepositoryError();
        }
        catch (Exception e)
        {
            return Result!RepositoryError.err(
                new RepositoryError("Failed to verify integrity: " ~ e.msg));
        }
    }
    
    /// Compute BLAKE3 hash of a file
    static Result!(string, RepositoryError) computeHash(string filePath) @trusted
    {
        if (!exists(filePath))
            return Result!(string, RepositoryError).err(
                new RepositoryError("File not found: " ~ filePath));
        
        try
        {
            auto data = cast(ubyte[])read(filePath);
            auto hash = Blake3.hashHex(data);
            return Result!(string, RepositoryError).ok(hash);
        }
        catch (Exception e)
        {
            return Result!(string, RepositoryError).err(
                new RepositoryError("Failed to compute hash: " ~ e.msg));
        }
    }
}

