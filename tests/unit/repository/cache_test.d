module tests.unit.repository.cache_test;

import infrastructure.repository.storage.cache;
import infrastructure.repository.core.types;
import std.file : write, mkdir, exists, remove, rmdirRecurse, tempDir;
import std.path : buildPath;
import std.datetime : Clock;

unittest
{
    // Test cache put and get
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-cache-put-get");
        auto cache = new RepositoryCache(testCacheDir);
        
        scope(exit)
        {
            if (exists(testCacheDir))
                rmdirRecurse(testCacheDir);
        }
        
        // Create test repository directory
        string testRepoDir = buildPath(tempDir(), "builder-test-repo");
        if (!exists(testRepoDir))
            mkdir(testRepoDir);
        
        scope(exit)
        {
            if (exists(testRepoDir))
                rmdirRecurse(testRepoDir);
        }
        
        // Put repository in cache
        auto putResult = cache.put("test-repo", testRepoDir, "abc123");
        assert(putResult.isOk, "Should successfully put repository in cache");
        
        // Get repository from cache
        auto getResult = cache.get("test-repo");
        assert(getResult.isOk, "Should successfully get repository from cache");
        
        auto cached = getResult.unwrap();
        assert(cached.name == "test-repo", "Cached repository should have correct name");
        assert(cached.cacheKey == "abc123", "Cached repository should have correct cache key");
        assert(cached.localPath == testRepoDir, "Cached repository should have correct local path");
    }
    
    // Test cache miss
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-cache-miss");
        auto cache = new RepositoryCache(testCacheDir);
        
        scope(exit)
        {
            if (exists(testCacheDir))
                rmdirRecurse(testCacheDir);
        }
        
        auto getResult = cache.get("nonexistent-repo");
        assert(getResult.isErr, "Should fail to get non-existent repository");
    }
    
    // Test cache has
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-cache-has");
        auto cache = new RepositoryCache(testCacheDir);
        
        scope(exit)
        {
            if (exists(testCacheDir))
                rmdirRecurse(testCacheDir);
        }
        
        assert(!cache.has("test-repo"), "Should not have repository before adding");
        
        // Create and add test repository
        string testRepoDir = buildPath(tempDir(), "builder-test-repo-has");
        if (!exists(testRepoDir))
            mkdir(testRepoDir);
        
        scope(exit)
        {
            if (exists(testRepoDir))
                rmdirRecurse(testRepoDir);
        }
        
        cache.put("test-repo", testRepoDir, "abc123");
        
        assert(cache.has("test-repo"), "Should have repository after adding");
    }
    
    // Test cache remove
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-cache-remove");
        auto cache = new RepositoryCache(testCacheDir);
        
        scope(exit)
        {
            if (exists(testCacheDir))
                rmdirRecurse(testCacheDir);
        }
        
        // Create and add test repository
        string testRepoDir = buildPath(tempDir(), "builder-test-repo-remove");
        if (!exists(testRepoDir))
            mkdir(testRepoDir);
        
        cache.put("test-repo", testRepoDir, "abc123");
        
        assert(cache.has("test-repo"), "Should have repository after adding");
        
        auto removeResult = cache.remove("test-repo");
        assert(removeResult.isOk, "Should successfully remove repository");
        
        assert(!cache.has("test-repo"), "Should not have repository after removing");
    }
    
    // Test cache clear
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-cache-clear");
        auto cache = new RepositoryCache(testCacheDir);
        
        scope(exit)
        {
            if (exists(testCacheDir))
                rmdirRecurse(testCacheDir);
        }
        
        // Add multiple repositories
        for (int i = 0; i < 3; i++)
        {
            string testRepoDir = buildPath(tempDir(), "builder-test-repo-clear-" ~ i.to!string);
            if (!exists(testRepoDir))
                mkdir(testRepoDir);
            
            cache.put("repo-" ~ i.to!string, testRepoDir, "key-" ~ i.to!string);
        }
        
        auto stats = cache.getStats();
        assert(stats.count == 3, "Should have 3 repositories");
        
        auto clearResult = cache.clear();
        assert(clearResult.isOk, "Should successfully clear cache");
        
        auto statsAfter = cache.getStats();
        assert(statsAfter.count == 0, "Should have 0 repositories after clear");
    }
    
    // Test cache statistics
    {
        string testCacheDir = buildPath(tempDir(), "builder-test-cache-stats");
        auto cache = new RepositoryCache(testCacheDir);
        
        scope(exit)
        {
            if (exists(testCacheDir))
                rmdirRecurse(testCacheDir);
        }
        
        auto statsEmpty = cache.getStats();
        assert(statsEmpty.count == 0, "Empty cache should have count 0");
        assert(statsEmpty.totalSize == 0, "Empty cache should have size 0");
        
        // Add repository
        string testRepoDir = buildPath(tempDir(), "builder-test-repo-stats");
        if (!exists(testRepoDir))
            mkdir(testRepoDir);
        
        scope(exit)
        {
            if (exists(testRepoDir))
                rmdirRecurse(testRepoDir);
        }
        
        // Create a test file
        write(buildPath(testRepoDir, "test.txt"), "test content");
        
        cache.put("test-repo", testRepoDir, "abc123");
        
        auto statsAfter = cache.getStats();
        assert(statsAfter.count == 1, "Cache should have 1 repository");
        assert(statsAfter.totalSize > 0, "Cache should have non-zero size");
    }
}

private import std.conv : to;

