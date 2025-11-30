module tests.unit.repository.types_test;

import infrastructure.repository.core.types;
import std.datetime : Clock;

unittest
{
    // Test RepositoryRule validation - valid HTTP repository
    {
        RepositoryRule rule;
        rule.name = "test-repo";
        rule.kind = RepositoryKind.Http;
        rule.url = "https://example.com/archive.tar.gz";
        rule.integrity = "abc123def456";
        
        auto result = rule.validate();
        assert(result.isOk, "Valid HTTP repository should pass validation");
    }
    
    // Test RepositoryRule validation - missing name
    {
        RepositoryRule rule;
        rule.kind = RepositoryKind.Http;
        rule.url = "https://example.com/archive.tar.gz";
        rule.integrity = "abc123";
        
        auto result = rule.validate();
        assert(result.isErr, "Repository with empty name should fail validation");
    }
    
    // Test RepositoryRule validation - missing URL for HTTP
    {
        RepositoryRule rule;
        rule.name = "test-repo";
        rule.kind = RepositoryKind.Http;
        rule.integrity = "abc123";
        
        auto result = rule.validate();
        assert(result.isErr, "HTTP repository without URL should fail validation");
    }
    
    // Test RepositoryRule validation - missing integrity for HTTP
    {
        RepositoryRule rule;
        rule.name = "test-repo";
        rule.kind = RepositoryKind.Http;
        rule.url = "https://example.com/archive.tar.gz";
        
        auto result = rule.validate();
        assert(result.isErr, "HTTP repository without integrity should fail validation");
    }
    
    // Test RepositoryRule validation - valid Git repository
    {
        RepositoryRule rule;
        rule.name = "git-repo";
        rule.kind = RepositoryKind.Git;
        rule.url = "https://github.com/user/repo.git";
        rule.gitCommit = "abc123";
        
        auto result = rule.validate();
        assert(result.isOk, "Valid Git repository should pass validation");
    }
    
    // Test RepositoryRule validation - Git without commit or tag
    {
        RepositoryRule rule;
        rule.name = "git-repo";
        rule.kind = RepositoryKind.Git;
        rule.url = "https://github.com/user/repo.git";
        
        auto result = rule.validate();
        assert(result.isErr, "Git repository without commit or tag should fail validation");
    }
    
    // Test RepositoryRule validation - valid local repository
    {
        RepositoryRule rule;
        rule.name = "local-repo";
        rule.kind = RepositoryKind.Local;
        rule.url = "/path/to/local/repo";
        
        auto result = rule.validate();
        assert(result.isOk, "Valid local repository should pass validation");
    }
    
    // Test cache key generation
    {
        RepositoryRule rule1;
        rule1.url = "https://example.com/archive.tar.gz";
        rule1.integrity = "abc123";
        
        RepositoryRule rule2;
        rule2.url = "https://example.com/archive.tar.gz";
        rule2.integrity = "abc123";
        
        assert(rule1.cacheKey() == rule2.cacheKey(), 
            "Same repository rules should generate same cache key");
        
        RepositoryRule rule3;
        rule3.url = "https://example.com/different.tar.gz";
        rule3.integrity = "def456";
        
        assert(rule1.cacheKey() != rule3.cacheKey(),
            "Different repository rules should generate different cache keys");
    }
}

unittest
{
    // Test CachedRepository validity check
    {
        import std.file : mkdir, rmdir, exists;
        import std.path : buildPath;
        
        string testDir = buildPath("/tmp", "builder-test-cached-repo");
        
        // Create test directory
        if (!exists(testDir))
            mkdir(testDir);
        
        scope(exit) 
        {
            if (exists(testDir))
                rmdir(testDir);
        }
        
        CachedRepository cached;
        cached.name = "test";
        cached.localPath = testDir;
        cached.fetchedAt = Clock.currTime();
        
        assert(cached.isValid(), "Cached repository with existing path should be valid");
        
        rmdir(testDir);
        assert(!cached.isValid(), "Cached repository with missing path should be invalid");
    }
}

unittest
{
    // Test ResolvedRepository target path building
    {
        ResolvedRepository resolved;
        resolved.name = "test-repo";
        resolved.path = "/path/to/repo";
        
        auto target1 = resolved.buildTargetPath("lib", "core");
        assert(target1 == "@test-repo//lib:core", "Should build correct target path");
        
        auto target2 = resolved.buildTargetPath("", "main");
        assert(target2 == "@test-repo//:main", "Should build correct target path without relative path");
    }
}

unittest
{
    // Test ArchiveFormat enum
    {
        assert(ArchiveFormat.Auto == ArchiveFormat.Auto);
        assert(ArchiveFormat.TarGz != ArchiveFormat.Zip);
        assert(ArchiveFormat.TarXz != ArchiveFormat.TarBz2);
    }
}

unittest
{
    // Test RepositoryKind enum
    {
        assert(RepositoryKind.Http != RepositoryKind.Git);
        assert(RepositoryKind.Git != RepositoryKind.Local);
        assert(RepositoryKind.Local != RepositoryKind.Http);
    }
}

