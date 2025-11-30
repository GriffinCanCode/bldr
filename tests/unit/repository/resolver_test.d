module tests.unit.repository.resolver_test;

import infrastructure.repository.resolution.resolver;
import infrastructure.repository.core.types;
import std.file : mkdir, exists, rmdirRecurse, tempDir;
import std.path : buildPath;

unittest
{
    // Test repository rule registration
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-resolver-register");
        string testWorkspaceRoot = buildPath(tempDir(), "builder-test-workspace");
        
        auto resolver = new RepositoryResolver(testCacheDir, testWorkspaceRoot);
        
        scope(exit)
        {
            if (exists(testCacheDir)) rmdirRecurse(testCacheDir);
            if (exists(testWorkspaceRoot)) rmdirRecurse(testWorkspaceRoot);
        }
        
        RepositoryRule rule;
        rule.name = "test-repo";
        rule.kind = RepositoryKind.Local;
        rule.url = "/tmp/test";
        
        auto result = resolver.registerRule(rule);
        assert(result.isOk, "Should successfully register valid rule");
    }
    
    // Test repository rule registration with invalid rule
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-resolver-invalid");
        string testWorkspaceRoot = buildPath(tempDir(), "builder-test-workspace-invalid");
        
        auto resolver = new RepositoryResolver(testCacheDir, testWorkspaceRoot);
        
        scope(exit)
        {
            if (exists(testCacheDir)) rmdirRecurse(testCacheDir);
            if (exists(testWorkspaceRoot)) rmdirRecurse(testWorkspaceRoot);
        }
        
        RepositoryRule rule;
        rule.name = "";  // Invalid: empty name
        rule.kind = RepositoryKind.Http;
        rule.url = "https://example.com";
        rule.integrity = "abc123";
        
        auto result = resolver.registerRule(rule);
        assert(result.isErr, "Should fail to register invalid rule");
    }
    
    // Test isExternalRef
    {
        assert(RepositoryResolver.isExternalRef("@repo//path:target"), 
            "@repo//path:target should be external ref");
        assert(RepositoryResolver.isExternalRef("@repo"),
            "@repo should be external ref");
        assert(!RepositoryResolver.isExternalRef("//path:target"),
            "//path:target should not be external ref");
        assert(!RepositoryResolver.isExternalRef(":target"),
            ":target should not be external ref");
    }
    
    // Test local repository resolution
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-resolver-local");
        string testWorkspaceRoot = buildPath(tempDir(), "builder-test-workspace-local");
        string testRepoPath = buildPath(tempDir(), "builder-test-local-repo");
        
        if (!exists(testRepoPath))
            mkdir(testRepoPath);
        
        auto resolver = new RepositoryResolver(testCacheDir, testWorkspaceRoot);
        
        scope(exit)
        {
            if (exists(testCacheDir)) rmdirRecurse(testCacheDir);
            if (exists(testWorkspaceRoot)) rmdirRecurse(testWorkspaceRoot);
            if (exists(testRepoPath)) rmdirRecurse(testRepoPath);
        }
        
        RepositoryRule rule;
        rule.name = "local-repo";
        rule.kind = RepositoryKind.Local;
        rule.url = testRepoPath;
        
        resolver.registerRule(rule);
        
        auto resolveResult = resolver.resolve("@local-repo");
        assert(resolveResult.isOk, "Should successfully resolve local repository");
        
        auto resolved = resolveResult.unwrap();
        assert(resolved.name == "local-repo", "Resolved repo should have correct name");
        assert(resolved.path == testRepoPath, "Resolved repo should have correct path");
    }
    
    // Test resolving unknown repository
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-resolver-unknown");
        string testWorkspaceRoot = buildPath(tempDir(), "builder-test-workspace-unknown");
        
        auto resolver = new RepositoryResolver(testCacheDir, testWorkspaceRoot);
        
        scope(exit)
        {
            if (exists(testCacheDir)) rmdirRecurse(testCacheDir);
            if (exists(testWorkspaceRoot)) rmdirRecurse(testWorkspaceRoot);
        }
        
        auto resolveResult = resolver.resolve("@unknown-repo");
        assert(resolveResult.isErr, "Should fail to resolve unknown repository");
    }
    
    // Test target reference parsing
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-resolver-target");
        string testWorkspaceRoot = buildPath(tempDir(), "builder-test-workspace-target");
        string testRepoPath = buildPath(tempDir(), "builder-test-target-repo");
        
        if (!exists(testRepoPath))
            mkdir(testRepoPath);
        
        auto resolver = new RepositoryResolver(testCacheDir, testWorkspaceRoot);
        
        scope(exit)
        {
            if (exists(testCacheDir)) rmdirRecurse(testCacheDir);
            if (exists(testWorkspaceRoot)) rmdirRecurse(testWorkspaceRoot);
            if (exists(testRepoPath)) rmdirRecurse(testRepoPath);
        }
        
        RepositoryRule rule;
        rule.name = "test-repo";
        rule.kind = RepositoryKind.Local;
        rule.url = testRepoPath;
        
        resolver.registerRule(rule);
        
        auto targetResult = resolver.resolveTarget("@test-repo//lib:core");
        assert(targetResult.isOk, "Should successfully resolve target reference");
        
        auto targetPath = targetResult.unwrap();
        assert(targetPath.indexOf("lib") >= 0, "Target path should contain lib directory");
    }
    
    // Test invalid target reference format
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-resolver-invalid-target");
        string testWorkspaceRoot = buildPath(tempDir(), "builder-test-workspace-invalid-target");
        
        auto resolver = new RepositoryResolver(testCacheDir, testWorkspaceRoot);
        
        scope(exit)
        {
            if (exists(testCacheDir)) rmdirRecurse(testCacheDir);
            if (exists(testWorkspaceRoot)) rmdirRecurse(testWorkspaceRoot);
        }
        
        auto targetResult = resolver.resolveTarget("@test-repo-missing-slash");
        assert(targetResult.isErr, "Should fail to resolve invalid target reference");
    }
}

private import std.string : indexOf;

