module infrastructure.repository.resolution.resolver;

import std.string : startsWith, split, format;
import std.algorithm : canFind;
import std.path : buildPath, absolutePath;
import infrastructure.repository.core.types;
import infrastructure.repository.storage.cache;
import infrastructure.repository.acquisition.fetcher;
import infrastructure.utils.logging;
import infrastructure.errors;

/// Repository resolver - resolves @repo// references to actual paths
final class RepositoryResolver
{
    private RepositoryRule[string] rules;     // name -> rule
    private ResolvedRepository[string] resolved;  // name -> resolved
    private RepositoryCache cache;
    private RepositoryFetcher fetcher;
    private string workspaceRoot;
    
    this(string cacheDir, string workspaceRoot) @safe
    {
        this.cache = new RepositoryCache(cacheDir);
        this.fetcher = new RepositoryFetcher(cacheDir);
        this.workspaceRoot = workspaceRoot;
    }
    
    /// Register a repository rule
    Result!RepositoryError registerRule(RepositoryRule rule) @system
    {
        auto validationResult = rule.validate();
        if (validationResult.isErr)
            return validationResult;
        
        if (rule.name in rules)
        {
            structuredLog.warning("overwriting_existing_repository_rule_").field("detail", "Overwriting existing repository rule: " ~ rule.name).emit();
        }
        
        rules[rule.name] = rule;
        structuredLog.debug_("registered_repository_").field("detail", "Registered repository: " ~ rule.name).emit();
        
        return Ok!RepositoryError();
    }
    
    /// Resolve repository reference to local path
    /// @param ref: Reference like "@llvm" or "@llvm//lib:Support"
    /// Returns: Absolute path to repository root
    Result!(ResolvedRepository, RepositoryError) resolve(string ref_) @trusted
    {
        // Parse reference format: @name or @name//path:target
        if (!ref_.startsWith("@"))
        {
            return Result!(ResolvedRepository, RepositoryError).err(
                new RepositoryError("External repository references must start with @: " ~ ref_));
        }
        
        // Extract repository name
        string repoName = ref_[1 .. $];
        auto slashIdx = repoName.indexOf("//");
        if (slashIdx >= 0)
        {
            repoName = repoName[0 .. slashIdx];
        }
        
        // Check if already resolved
        auto existing = repoName in resolved;
        if (existing !is null)
        {
            return Result!(ResolvedRepository, RepositoryError).ok(*existing);
        }
        
        // Get repository rule
        auto rule = repoName in rules;
        if (rule is null)
        {
            return Result!(ResolvedRepository, RepositoryError).err(
                new RepositoryError("Unknown repository: " ~ repoName));
        }
        
        // Check cache first
        auto cacheResult = cache.get(repoName);
        if (cacheResult.isOk)
        {
            auto cached = cacheResult.unwrap();
            auto resolved_ = ResolvedRepository(repoName, cached.localPath, *rule);
            resolved[repoName] = resolved_;
            
            structuredLog.debug_("resolved_").field("detail", "Resolved " ~ repoName ~ " from cache").emit();
            return Result!(ResolvedRepository, RepositoryError).ok(resolved_);
        }
        
        // Fetch repository
        structuredLog.info("resolving_repository_").field("detail", "Resolving repository: " ~ repoName).emit();
        auto fetchResult = fetcher.fetch(*rule);
        if (fetchResult.isErr)
            return Result!(ResolvedRepository, RepositoryError).err(fetchResult.unwrapErr());
        
        auto localPath = fetchResult.unwrap();
        
        // Store in cache
        auto cacheKey = rule.cacheKey();
        auto putResult = cache.put(repoName, localPath, cacheKey);
        if (putResult.isErr)
        {
            structuredLog.warning("failed_to_cache_repository_").field("detail", "Failed to cache repository: " ~ putResult.unwrapErr().message()).emit();
        }
        
        // Store resolved repository
        auto resolved_ = ResolvedRepository(repoName, localPath, *rule);
        resolved[repoName] = resolved_;
        
        structuredLog.info("resolved_repository_").field("detail", "Resolved repository: " ~ repoName ~ " -> " ~ localPath).emit();
        
        return Result!(ResolvedRepository, RepositoryError).ok(resolved_);
    }
    
    /// Resolve full target reference to absolute path
    /// @param ref: Reference like "@llvm//lib:Support"
    /// Returns: Absolute path to target file/directory
    Result!(string, RepositoryError) resolveTarget(string ref_) @trusted
    {
        if (!ref_.startsWith("@"))
        {
            return Result!(string, RepositoryError).err(
                new RepositoryError("External target references must start with @: " ~ ref_));
        }
        
        // Parse: @repo//path:target
        auto parts = ref_[1 .. $].split("//");
        if (parts.length != 2)
        {
            return Result!(string, RepositoryError).err(
                new RepositoryError("Invalid external target reference format: " ~ ref_));
        }
        
        string repoName = parts[0];
        string pathAndTarget = parts[1];
        
        // Resolve repository first
        auto repoResult = resolve("@" ~ repoName);
        if (repoResult.isErr)
            return Result!(string, RepositoryError).err(repoResult.unwrapErr());
        
        auto repo = repoResult.unwrap();
        
        // Parse path:target
        auto colonIdx = pathAndTarget.lastIndexOf(":");
        if (colonIdx < 0)
        {
            return Result!(string, RepositoryError).err(
                new RepositoryError("Invalid target reference (missing :target): " ~ ref_));
        }
        
        string relativePath = pathAndTarget[0 .. colonIdx];
        string targetName = pathAndTarget[colonIdx + 1 .. $];
        
        // Build absolute path
        string absolutePath_;
        if (relativePath.length == 0)
        {
            absolutePath_ = repo.path;
        }
        else
        {
            absolutePath_ = buildPath(repo.path, relativePath);
        }
        
        return Result!(string, RepositoryError).ok(absolutePath_);
    }
    
    /// Check if reference is external repository
    static bool isExternalRef(string ref_) pure @safe nothrow
    {
        return ref_.startsWith("@");
    }
    
    /// Get all registered repositories
    const(RepositoryRule)[] getRules() const pure @safe
    {
        return rules.byValue.array;
    }
    
    /// Get cache statistics
    auto getCacheStats() const @safe
    {
        return cache.getStats();
    }
    
    /// Clear repository cache
    Result!RepositoryError clearCache() @trusted
    {
        return cache.clear();
    }
}

private import std.string : indexOf, lastIndexOf;
private import std.array : array;

