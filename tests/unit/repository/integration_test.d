module tests.unit.repository.integration_test;

import infrastructure.repository;
import std.file : write, mkdir, exists, rmdirRecurse, tempDir;
import std.path : buildPath;

unittest
{
    // Test end-to-end repository workflow: register -> fetch -> resolve -> cache
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-integration");
        string testWorkspaceRoot = buildPath(tempDir(), "builder-test-workspace-integration");
        string testRepoPath = buildPath(tempDir(), "builder-test-integration-repo");
        
        // Create test repository directory
        if (!exists(testRepoPath))
            mkdir(testRepoPath);
        
        // Create a test file in the repository
        write(buildPath(testRepoPath, "README.md"), "# Test Repository");
        
        scope(exit)
        {
            if (exists(testCacheDir)) rmdirRecurse(testCacheDir);
            if (exists(testWorkspaceRoot)) rmdirRecurse(testWorkspaceRoot);
            if (exists(testRepoPath)) rmdirRecurse(testRepoPath);
        }
        
        // Create resolver and cache
        auto resolver = new RepositoryResolver(testCacheDir, testWorkspaceRoot);
        
        // Register repository rule
        RepositoryRule rule;
        rule.name = "test-integration";
        rule.kind = RepositoryKind.Local;
        rule.url = testRepoPath;
        
        auto registerResult = resolver.registerRule(rule);
        assert(registerResult.isOk, "Should successfully register repository");
        
        // Resolve repository (should fetch and cache)
        auto resolveResult = resolver.resolve("@test-integration");
        assert(resolveResult.isOk, "Should successfully resolve repository");
        
        auto resolved = resolveResult.unwrap();
        assert(resolved.name == "test-integration", "Resolved repo should have correct name");
        assert(resolved.path == testRepoPath, "Resolved repo should have correct path");
        
        // Check cache
        auto cacheStats = resolver.getCacheStats();
        assert(cacheStats.count == 1, "Cache should have 1 repository");
        
        // Resolve again (should hit cache)
        auto resolveResult2 = resolver.resolve("@test-integration");
        assert(resolveResult2.isOk, "Second resolution should succeed");
        
        // Resolve target reference
        auto targetResult = resolver.resolveTarget("@test-integration//lib:core");
        assert(targetResult.isOk, "Should successfully resolve target reference");
    }
    
    // Test HTTP repository validation
    {
        RepositoryRule httpRule;
        httpRule.name = "http-repo";
        httpRule.kind = RepositoryKind.Http;
        httpRule.url = "https://example.com/archive.tar.gz";
        httpRule.integrity = "abc123def456789012345678901234567890123456789012345678901234";
        
        auto validationResult = httpRule.validate();
        assert(validationResult.isOk, "Valid HTTP repository should pass validation");
    }
    
    // Test Git repository validation
    {
        RepositoryRule gitRule;
        gitRule.name = "git-repo";
        gitRule.kind = RepositoryKind.Git;
        gitRule.url = "https://github.com/user/repo.git";
        gitRule.gitCommit = "abcdef1234567890";
        
        auto validationResult = gitRule.validate();
        assert(validationResult.isOk, "Valid Git repository should pass validation");
    }
    
    // Test repository rule with Git tag
    {
        RepositoryRule gitTagRule;
        gitTagRule.name = "git-tag-repo";
        gitTagRule.kind = RepositoryKind.Git;
        gitTagRule.url = "https://github.com/user/repo.git";
        gitTagRule.gitTag = "v1.0.0";
        
        auto validationResult = gitTagRule.validate();
        assert(validationResult.isOk, "Git repository with tag should pass validation");
    }
    
    // Test multiple repositories in resolver
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-multi");
        string testWorkspaceRoot = buildPath(tempDir(), "builder-test-workspace-multi");
        
        auto resolver = new RepositoryResolver(testCacheDir, testWorkspaceRoot);
        
        scope(exit)
        {
            if (exists(testCacheDir)) rmdirRecurse(testCacheDir);
            if (exists(testWorkspaceRoot)) rmdirRecurse(testWorkspaceRoot);
        }
        
        // Register multiple repositories
        string[] createdRepos;
        scope(exit)
        {
            foreach (repo; createdRepos)
                if (exists(repo)) rmdirRecurse(repo);
        }

        for (int i = 0; i < 3; i++)
        {
            string repoPath = buildPath(tempDir(), "builder-test-repo-multi-" ~ i.to!string);
            if (!exists(repoPath))
                mkdir(repoPath);
            createdRepos ~= repoPath;
            
            RepositoryRule rule;
            rule.name = "repo-" ~ i.to!string;
            rule.kind = RepositoryKind.Local;
            rule.url = repoPath;
            
            auto result = resolver.registerRule(rule);
            assert(result.isOk, "Should register repository " ~ i.to!string);
        }
        
        // Verify all repositories can be resolved
        for (int i = 0; i < 3; i++)
        {
            auto resolveResult = resolver.resolve("@repo-" ~ i.to!string);
            assert(resolveResult.isOk, "Should resolve repository " ~ i.to!string);
        }
    }
    
    // Test stripPrefix in repository rule
    {
        RepositoryRule rule;
        rule.name = "stripped-repo";
        rule.kind = RepositoryKind.Http;
        rule.url = "https://example.com/project-1.0.0.tar.gz";
        rule.integrity = "abc123def456789012345678901234567890123456789012345678901234";
        rule.stripPrefix = "project-1.0.0";
        
        auto validationResult = rule.validate();
        assert(validationResult.isOk, "Repository with stripPrefix should pass validation");
        assert(rule.stripPrefix == "project-1.0.0", "stripPrefix should be preserved");
    }
    
    // Test cache key uniqueness
    {
        RepositoryRule rule1;
        rule1.url = "https://example.com/archive-v1.tar.gz";
        rule1.integrity = "hash1";
        
        RepositoryRule rule2;
        rule2.url = "https://example.com/archive-v2.tar.gz";
        rule2.integrity = "hash2";
        
        assert(rule1.cacheKey() != rule2.cacheKey(),
            "Different repositories should have different cache keys");
    }
}

private import std.conv : to;

