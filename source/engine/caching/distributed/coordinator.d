module engine.caching.distributed.coordinator;

import std.file : exists, read, write, mkdirRecurse, isDir;
import std.path : buildPath, dirName;
import std.algorithm : min;
import std.conv : to;
import engine.caching.targets.cache : BuildCache;
import engine.caching.actions.action : ActionCache, ActionId;
import engine.caching.distributed.remote.client : RemoteCacheClient;
import infrastructure.utils.files.hash : FastHash;
import infrastructure.errors;

/// Distributed cache coordinator
/// Manages local and remote cache tiers with fallback logic
/// 
/// Strategy:
/// - Read: Local first, then remote (pull on miss)
/// - Write: Local immediately, remote async (push in background)
/// - Transparency: Handlers don't need to know about distribution
final class DistributedCache
{
    private BuildCache localCache;
    private ActionCache actionCache;
    private RemoteCacheClient remoteCache;
    private string cacheDir;
    
    /// Constructor
    this(BuildCache localCache, ActionCache actionCache, RemoteCacheClient remoteCache, string cacheDir) @safe
    {
        this.localCache = localCache;
        this.actionCache = actionCache;
        this.remoteCache = remoteCache;
        this.cacheDir = cacheDir;
    }
    
    /// Check if target is cached (local or remote)
    bool isCached(string targetId, scope const(string)[] sources, scope const(string)[] deps) @trusted
    {
        // Check local cache first (fast path)
        if (localCache.isCached(targetId, sources, deps)) return true;
        if (remoteCache is null) return false;
        
        // Check remote cache
        auto hashResult = computeTargetHash(targetId, sources, deps);
        if (hashResult.isErr) return false;
        
        auto hasResult = remoteCache.has(hashResult.unwrap());
        if (hasResult.isErr || !hasResult.unwrap()) return false;
        
        // Pull from remote and store locally
        return pullFromRemote(hashResult.unwrap(), targetId).isOk;
    }
    
    /// Update cache after successful build
    void update(string targetId, scope const(string)[] sources, scope const(string)[] deps, string outputHash) @trusted
    {
        // Update local cache immediately
        localCache.update(targetId, sources, deps, outputHash);
        
        // Push to remote cache asynchronously if available
        if (remoteCache !is null)
        {
            // Compute target hash
            auto hashResult = computeTargetHash(targetId, sources, deps);
            if (hashResult.isOk)
            {
                auto targetHash = hashResult.unwrap();
                
                // Push artifact asynchronously (spawn thread to avoid blocking build)
                import core.thread : Thread;
                new Thread(() => pushArtifactToRemote(targetHash, targetId, outputHash)).start();
            }
        }
    }
    
    /// Record action for fine-grained caching
    void recordAction(ActionId actionId, string[] inputs, string[] outputs,
                     string[string] metadata, bool success) @trusted
    {
        // Update local action cache
        actionCache.update(actionId, inputs, outputs, metadata, success);
        
        // Push action artifacts to remote cache if available
        if (remoteCache !is null && success && outputs.length > 0)
        {
            import core.thread : Thread;
            new Thread(() => pushActionArtifactsToRemote(actionId, outputs)).start();
        }
    }
    
    /// Flush all caches
    void flush() @trusted
    {
        localCache.flush();
        actionCache.flush();
    }
    
    /// Close all caches
    void close() @trusted
    {
        if (localCache !is null) localCache.close();
        if (actionCache !is null) actionCache.close();
    }
    
    private BuildResult!string computeTargetHash(
        string targetId,
        scope const(string)[] sources,
        scope const(string)[] deps
    ) @trusted
    {
        import std.digest.sha : SHA256, toHexString;
        import std.conv : to;
        
        try
        {
            SHA256 hash;
            hash.start();
            
            // Hash target ID
            hash.put(cast(ubyte[])targetId);
            
            // Hash all sources
            foreach (source; sources)
            {
                if (exists(source))
                {
                    auto sourceHash = FastHash.hashFile(source);
                    hash.put(cast(ubyte[])sourceHash);
                }
            }
            
            // Hash dependencies
            foreach (dep; deps)
            {
                hash.put(cast(ubyte[])dep);
            }
            
            auto result = toHexString(hash.finish()).to!string;
            return Ok!(string, BuildError)(result);
        }
        catch (Exception e)
        {
            auto error = new CacheError(
                "Failed to compute target hash: " ~ e.msg,
                ErrorCode.CacheLoadFailed
            );
            return Err!(string, BuildError)(error);
        }
    }
    
    private VoidBuildResult pullFromRemote(string targetHash, string targetId) @trusted
    {
        try
        {
            // Fetch artifact from remote
            auto fetchResult = remoteCache.get(targetHash);
            if (fetchResult.isErr)
            {
                return VoidBuildResult.err(fetchResult.unwrapErr());
            }
            
            auto artifactData = fetchResult.unwrap();
            
            // Store artifact locally
            immutable artifactPath = buildPath(cacheDir, "artifacts", targetHash);
            immutable artifactDir = dirName(artifactPath);
            
            if (!exists(artifactDir))
                mkdirRecurse(artifactDir);
            
            write(artifactPath, artifactData);
            
            return Ok!BuildError();
        }
        catch (Exception e)
        {
            BuildError error = new CacheError(
                "Failed to pull from remote cache: " ~ e.msg,
                ErrorCode.CacheLoadFailed
            );
            return VoidBuildResult.err(error);
        }
    }
    
    /// Push artifact to remote cache (runs asynchronously)
    private void pushArtifactToRemote(string targetHash, string targetId, string outputHash) @trusted nothrow
    {
        try
        {
            immutable artifactPath = buildPath(cacheDir, "artifacts", outputHash);
            if (!exists(artifactPath)) return;
            
            auto artifactData = cast(ubyte[])read(artifactPath);
            auto serialized = serializeArtifact(targetId, artifactData);
            remoteCache.put(targetHash, serialized);
        }
        catch (Exception e) {}
    }
    
    /// Push action artifacts to remote cache (runs asynchronously)
    private void pushActionArtifactsToRemote(ActionId actionId, string[] outputs) @trusted nothrow
    {
        try
        {
            import std.digest.sha : SHA256, toHexString;
            
            // Compute action hash
            SHA256 hash;
            hash.start();
            hash.put(cast(ubyte[])actionId.toString());
            auto actionHash = toHexString(hash.finish()).to!string;
            
            // Collect and serialize all output files
            ubyte[] combined;
            foreach (output; outputs)
            {
                if (exists(output) && !isDir(output))
                {
                    auto data = cast(ubyte[])read(output);
                    
                    // Store with length prefix
                    import std.bitmanip : nativeToBigEndian;
                    combined ~= nativeToBigEndian(cast(uint)data.length);
                    combined ~= data;
                }
            }
            
            if (combined.length > 0)
            {
                // Push to remote cache
                auto pushResult = remoteCache.put(actionHash, combined);
            }
        }
        catch (Exception e)
        {
            // Silently ignore errors in background thread
        }
    }
    
    /// Serialize artifact with metadata
    private ubyte[] serializeArtifact(string targetId, const(ubyte)[] data) pure @trusted
    {
        import std.bitmanip : write;
        
        ubyte[] buffer;
        buffer.reserve(data.length + 256);
        
        // Version byte
        buffer.write!ubyte(1, buffer.length);
        
        // Target ID (length-prefixed)
        import std.utf : toUTF8;
        immutable targetIdBytes = targetId.toUTF8();
        buffer.write!uint(cast(uint)targetIdBytes.length, buffer.length);
        buffer ~= targetIdBytes;
        
        // Data size
        buffer.write!ulong(data.length, buffer.length);
        
        // Data
        buffer ~= data;
        
        return buffer;
    }
}


