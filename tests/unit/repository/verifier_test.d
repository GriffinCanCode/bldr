module tests.unit.repository.verifier_test;

import infrastructure.repository.acquisition.verifier;
import infrastructure.repository.core.types;
import std.file : write, remove, exists;
import std.path : buildPath;

unittest
{
    // Test BLAKE3 hash verification - success case
    {
        string testFile = buildPath("/tmp", "builder-test-verify-success.txt");
        string testContent = "Hello, Builder!";
        write(testFile, testContent);
        
        scope(exit)
        {
            if (exists(testFile))
                remove(testFile);
        }
        
        // Compute hash of test content
        auto computeResult = IntegrityVerifier.computeHash(testFile);
        assert(computeResult.isOk, "Should compute hash successfully");
        
        auto hash = computeResult.unwrap();
        assert(hash.length == 64, "BLAKE3 hash should be 64 hex characters");
        
        // Verify with correct hash
        auto verifyResult = IntegrityVerifier.verify(testFile, hash);
        assert(verifyResult.isOk, "Verification should succeed with correct hash");
    }
    
    // Test BLAKE3 hash verification - failure case
    {
        string testFile = buildPath("/tmp", "builder-test-verify-fail.txt");
        string testContent = "Hello, Builder!";
        write(testFile, testContent);
        
        scope(exit)
        {
            if (exists(testFile))
                remove(testFile);
        }
        
        // Use wrong hash
        string wrongHash = "0000000000000000000000000000000000000000000000000000000000000000";
        
        auto verifyResult = IntegrityVerifier.verify(testFile, wrongHash);
        assert(verifyResult.isErr, "Verification should fail with wrong hash");
        
        auto error = verifyResult.unwrapErr();
        assert(error.message().indexOf("Integrity check failed") >= 0, 
            "Error message should mention integrity check failure");
    }
    
    // Test verification with non-existent file
    {
        string nonExistent = "/tmp/builder-test-nonexistent-file.txt";
        string hash = "abc123def456";
        
        auto result = IntegrityVerifier.verify(nonExistent, hash);
        assert(result.isErr, "Verification of non-existent file should fail");
    }
    
    // Test hash computation with non-existent file
    {
        string nonExistent = "/tmp/builder-test-nonexistent-file.txt";
        
        auto result = IntegrityVerifier.computeHash(nonExistent);
        assert(result.isErr, "Hash computation of non-existent file should fail");
    }
    
    // Test unsupported hash format
    {
        string testFile = buildPath("/tmp", "builder-test-verify-format.txt");
        write(testFile, "test");
        
        scope(exit)
        {
            if (exists(testFile))
                remove(testFile);
        }
        
        // Too short hash
        string shortHash = "abc123";
        auto result = IntegrityVerifier.verify(testFile, shortHash);
        assert(result.isErr, "Should reject hash with wrong length");
    }
    
    // Test hash consistency
    {
        string testFile1 = buildPath("/tmp", "builder-test-consistency1.txt");
        string testFile2 = buildPath("/tmp", "builder-test-consistency2.txt");
        string testContent = "Same content";
        
        write(testFile1, testContent);
        write(testFile2, testContent);
        
        scope(exit)
        {
            if (exists(testFile1)) remove(testFile1);
            if (exists(testFile2)) remove(testFile2);
        }
        
        auto hash1 = IntegrityVerifier.computeHash(testFile1);
        auto hash2 = IntegrityVerifier.computeHash(testFile2);
        
        assert(hash1.isOk && hash2.isOk, "Should compute both hashes");
        assert(hash1.unwrap() == hash2.unwrap(), 
            "Same content should produce same hash");
    }
}

