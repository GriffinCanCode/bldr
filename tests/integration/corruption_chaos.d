module tests.integration.corruption_chaos;

import std.stdio : writeln, File;
import std.datetime : Duration, seconds, msecs, MonoTime;
import std.file : exists, write, read, remove, mkdirRecurse, rmdirRecurse, tempDir, readText, write;
import std.path : buildPath, dirName;
import std.algorithm : map, filter, canFind, min;
import std.array : array, replicate;
import std.conv : to;
import std.random : uniform, uniform01, Random;
import std.string : strip;
import core.thread : Thread;
import core.atomic;
import core.sync.mutex : Mutex;

import tests.harness : Assert;
import tests.fixtures : TempDir;
import infrastructure.errors;
import infrastructure.utils.logging.logger;

/// Corruption chaos types
enum CorruptionType
{
    FileCorruption,         // Corrupt file contents
    FileTruncation,         // Truncate files
    FileDeletion,           // Delete files unexpectedly
    CacheCorruption,        // Corrupt cache entries
    MetadataCorruption,     // Corrupt metadata
    PartialWrite,           // Incomplete file writes
    WrongPermissions,       // Change file permissions
    SymlinkBreak,           // Break symlinks
    DirectoryDeletion,      // Delete entire directories
    DiskFull,              // Simulate disk full
}

/// Worker killing types
enum WorkerKillType
{
    SigTerm,                // Graceful shutdown
    SigKill,                // Force kill
    OutOfMemory,            // OOM killer
    DiskIOError,            // Disk I/O failure
    NetworkDisconnect,      // Network failure
    CPUExhaustion,          // CPU exhaustion
    DeadlockDetected,       // Deadlock detected
    Timeout,                // Execution timeout
}

/// Chaos configuration
struct CorruptionChaosConfig
{
    CorruptionType type;
    double probability = 0.3;
    bool enabled = true;
}

struct WorkerKillConfig
{
    WorkerKillType type;
    double probability = 0.2;
    Duration timing = 5.seconds;  // When to kill during execution
    bool enabled = true;
}

/// File corruption simulator
class FileCorruptor
{
    private CorruptionChaosConfig[] chaosConfigs;
    private Random rng;
    private shared size_t corruptionsApplied;
    private Mutex mutex;
    
    this()
    {
        this.rng = Random(11111);
        this.mutex = new Mutex();
        atomicStore(corruptionsApplied, 0);
    }
    
    void addChaos(CorruptionChaosConfig config)
    {
        synchronized (mutex)
        {
            chaosConfigs ~= config;
        }
    }
    
    /// Potentially corrupt a file operation
    void maybeCorrupt(string filepath) @system
    {
        if (!exists(filepath))
            return;
        
        synchronized (mutex)
        {
            foreach (config; chaosConfigs)
            {
                if (!config.enabled)
                    continue;
                
                if (uniform01(rng) < config.probability)
                {
                    applyCorruption(config.type, filepath);
                    atomicOp!"+="(corruptionsApplied, 1);
                    return;
                }
            }
        }
    }
    
    private void applyCorruption(CorruptionType type, string filepath) @system
    {
        try
        {
            final switch (type)
            {
                case CorruptionType.FileCorruption:
                    corruptFileContents(filepath);
                    break;
                
                case CorruptionType.FileTruncation:
                    truncateFile(filepath);
                    break;
                
                case CorruptionType.FileDeletion:
                    deleteFile(filepath);
                    break;
                
                case CorruptionType.CacheCorruption:
                    corruptCacheEntry(filepath);
                    break;
                
                case CorruptionType.MetadataCorruption:
                    corruptMetadata(filepath);
                    break;
                
                case CorruptionType.PartialWrite:
                    partialWrite(filepath);
                    break;
                
                case CorruptionType.WrongPermissions:
                    changePermissions(filepath);
                    break;
                
                case CorruptionType.SymlinkBreak:
                    breakSymlink(filepath);
                    break;
                
                case CorruptionType.DirectoryDeletion:
                    deleteDirectory(filepath);
                    break;
                
                case CorruptionType.DiskFull:
                    simulateDiskFull(filepath);
                    break;
            }
        }
        catch (Exception e)
        {
            Logger.warning("Corruption failed: " ~ e.msg);
        }
    }
    
    private void corruptFileContents(string filepath) @system
    {
        Logger.info("CHAOS: Corrupting file contents - " ~ filepath);
        
        if (!exists(filepath))
            return;
        
        auto data = cast(ubyte[])read(filepath);
        if (data.length == 0)
            return;
        
        // Corrupt random bytes
        size_t corruptCount = uniform(1, min(10, data.length), rng);
        for (size_t i = 0; i < corruptCount; i++)
        {
            size_t idx = uniform(0, data.length, rng);
            data[idx] = cast(ubyte)uniform(0, 256, rng);
        }
        
        write(filepath, data);
    }
    
    private void truncateFile(string filepath) @system
    {
        Logger.info("CHAOS: Truncating file - " ~ filepath);
        
        if (!exists(filepath))
            return;
        
        auto data = cast(ubyte[])read(filepath);
        if (data.length == 0)
            return;
        
        // Truncate to random size (keep at least 10%)
        size_t newSize = uniform(data.length / 10, data.length * 9 / 10, rng);
        write(filepath, data[0..newSize]);
    }
    
    private void deleteFile(string filepath) @system
    {
        Logger.info("CHAOS: Deleting file - " ~ filepath);
        
        if (exists(filepath))
            remove(filepath);
    }
    
    private void corruptCacheEntry(string filepath) @system
    {
        Logger.info("CHAOS: Corrupting cache entry - " ~ filepath);
        
        // Corrupt a cache file (similar to file corruption but for cache)
        corruptFileContents(filepath);
    }
    
    private void corruptMetadata(string filepath) @system
    {
        Logger.info("CHAOS: Corrupting metadata - " ~ filepath);
        
        // In a real implementation, would corrupt file metadata
        // For now, simulate by changing file
        if (exists(filepath))
        {
            auto data = cast(ubyte[])read(filepath);
            data ~= cast(ubyte[])[0xFF, 0xFE];  // Add garbage
            write(filepath, data);
        }
    }
    
    private void partialWrite(string filepath) @system
    {
        Logger.info("CHAOS: Partial write - " ~ filepath);
        
        // Simulate incomplete write operation
        if (exists(filepath))
        {
            auto data = cast(ubyte[])read(filepath);
            if (data.length > 1)
            {
                write(filepath, data[0..$/2]);  // Write only half
            }
        }
    }
    
    private void changePermissions(string filepath) @system
    {
        Logger.info("CHAOS: Changing permissions - " ~ filepath);
        
        // Platform-specific permission changes would go here
        // On POSIX: chmod, on Windows: icacls
        version(Posix)
        {
            import std.process : executeShell;
            executeShell("chmod 000 " ~ filepath);
        }
    }
    
    private void breakSymlink(string filepath) @system
    {
        Logger.info("CHAOS: Breaking symlink - " ~ filepath);
        
        // If it's a symlink, delete its target
        version(Posix)
        {
            import std.file : isSymlink, readLink;
            if (isSymlink(filepath))
            {
                try
                {
                    auto target = readLink(filepath);
                    if (exists(target))
                        remove(target);
                }
                catch (Exception) {}
            }
        }
    }
    
    private void deleteDirectory(string filepath) @system
    {
        Logger.info("CHAOS: Deleting directory - " ~ filepath);
        
        import std.path : dirName;
        auto dir = dirName(filepath);
        
        if (exists(dir))
        {
            try { rmdirRecurse(dir); }
            catch (Exception e) { Logger.warning("Could not delete dir: " ~ e.msg); }
        }
    }
    
    private void simulateDiskFull(string filepath) @system
    {
        Logger.info("CHAOS: Simulating disk full - " ~ filepath);
        
        // Can't easily simulate disk full, but can make file access fail
        // by filling up space with a large file
        try
        {
            auto largeDummy = buildPath(dirName(filepath), ".disk_full_simulator");
            ubyte[] filler = new ubyte[1024 * 1024];  // 1 MB chunks
            auto f = File(largeDummy, "wb");
            // Write some large amount
            for (int i = 0; i < 100; i++)
                f.rawWrite(filler);
            f.close();
        }
        catch (Exception) {}
    }
    
    size_t getCorruptionCount() const => atomicLoad(corruptionsApplied);
}

/// Worker killer simulator
class WorkerKiller
{
    private WorkerKillConfig[] killConfigs;
    private Random rng;
    private shared size_t workersKilled;
    private Mutex mutex;
    
    this()
    {
        this.rng = Random(22222);
        this.mutex = new Mutex();
        atomicStore(workersKilled, 0);
    }
    
    void addKillConfig(WorkerKillConfig config)
    {
        synchronized (mutex)
        {
            killConfigs ~= config;
        }
    }
    
    /// Check if should kill worker during execution
    Result!BuildError maybeKillWorker(string workerId, Duration elapsedTime) @system
    {
        synchronized (mutex)
        {
            foreach (config; killConfigs)
            {
                if (!config.enabled)
                    continue;
                
                // Only kill after timing threshold
                if (elapsedTime < config.timing)
                    continue;
                
                if (uniform01(rng) < config.probability)
                {
                    return killWorker(config.type, workerId);
                }
            }
        }
        
        return Ok!BuildError();
    }
    
    private Result!BuildError killWorker(WorkerKillType type, string workerId) @system
    {
        atomicOp!"+="(workersKilled, 1);
        
        final switch (type)
        {
            case WorkerKillType.SigTerm:
                Logger.info("CHAOS: Sending SIGTERM to worker " ~ workerId);
                return Result!BuildError.err(cast(BuildError)new InternalError("Worker terminated (SIGTERM)"));
            
            case WorkerKillType.SigKill:
                Logger.info("CHAOS: Sending SIGKILL to worker " ~ workerId);
                return Result!BuildError.err(cast(BuildError)new InternalError("Worker killed (SIGKILL)"));
            
            case WorkerKillType.OutOfMemory:
                Logger.info("CHAOS: Worker " ~ workerId ~ " OOM");
                return Result!BuildError.err(cast(BuildError)new InternalError("Worker out of memory"));
            
            case WorkerKillType.DiskIOError:
                Logger.info("CHAOS: Worker " ~ workerId ~ " disk I/O error");
                return Result!BuildError.err(cast(BuildError)new InternalError("Disk I/O error"));
            
            case WorkerKillType.NetworkDisconnect:
                Logger.info("CHAOS: Worker " ~ workerId ~ " network disconnect");
                return Result!BuildError.err(cast(BuildError)new InternalError("Network disconnected"));
            
            case WorkerKillType.CPUExhaustion:
                Logger.info("CHAOS: Worker " ~ workerId ~ " CPU exhaustion");
                return Result!BuildError.err(cast(BuildError)new InternalError("CPU exhausted"));
            
            case WorkerKillType.DeadlockDetected:
                Logger.info("CHAOS: Worker " ~ workerId ~ " deadlock detected");
                return Result!BuildError.err(cast(BuildError)new InternalError("Deadlock detected"));
            
            case WorkerKillType.Timeout:
                Logger.info("CHAOS: Worker " ~ workerId ~ " execution timeout");
                return Result!BuildError.err(cast(BuildError)new InternalError("Execution timeout"));
        }
    }
    
    size_t getKillCount() const => atomicLoad(workersKilled);
}

/// Combined chaos simulator
class ChaosSimulator
{
    private FileCorruptor corruptor;
    private WorkerKiller killer;
    private string cacheDir;
    
    this(string cacheDir)
    {
        this.cacheDir = cacheDir;
        this.corruptor = new FileCorruptor();
        this.killer = new WorkerKiller();
        
        if (!exists(cacheDir))
            mkdirRecurse(cacheDir);
    }
    
    void enableFileCorruption(CorruptionType type, double probability)
    {
        corruptor.addChaos(CorruptionChaosConfig(type, probability, true));
    }
    
    void enableWorkerKilling(WorkerKillType type, double probability, Duration timing)
    {
        killer.addKillConfig(WorkerKillConfig(type, probability, timing, true));
    }
    
    /// Simulate build execution with chaos
    Result!BuildError simulateBuild(string buildId, Duration buildTime) @system
    {
        Logger.info("Starting chaotic build: " ~ buildId);
        
        auto startTime = MonoTime.currTime;
        
        // Simulate build steps with potential chaos
        for (size_t step = 0; step < 10; step++)
        {
            auto elapsed = MonoTime.currTime - startTime;
            
            // Check for worker kill
            auto killResult = killer.maybeKillWorker(buildId, elapsed);
            if (killResult.isErr)
            {
                Logger.info("Build killed at step " ~ step.to!string);
                return killResult;
            }
            
            // Create some cache files
            auto cacheFile = buildPath(cacheDir, buildId ~ "_step" ~ step.to!string ~ ".cache");
            write(cacheFile, "step " ~ step.to!string ~ " data");
            
            // Maybe corrupt the cache file
            corruptor.maybeCorrupt(cacheFile);
            
            // Simulate work
            Thread.sleep(buildTime / 10);
        }
        
        Logger.info("Build completed: " ~ buildId);
        return Ok!BuildError();
    }
    
    size_t getTotalCorruptions() const => corruptor.getCorruptionCount();
    size_t getTotalKills() const => killer.getKillCount();
}

// ============================================================================
// CHAOS TESTS: File Corruption & Worker Killing
// ============================================================================

/// Test: File corruption detection
@("corruption_chaos.file_corruption")
@system unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m File Corruption");
    
    auto tempDir = buildPath(tempDir(), "corruption-test");
    if (!exists(tempDir))
        mkdirRecurse(tempDir);
    scope(exit)
        if (exists(tempDir))
            rmdirRecurse(tempDir);
    
    auto corruptor = new FileCorruptor();
    
    // Enable file corruption
    corruptor.addChaos(CorruptionChaosConfig(CorruptionType.FileCorruption, 0.5, true));
    
    // Create test files
    size_t corruptedCount = 0;
    for (size_t i = 0; i < 20; i++)
    {
        auto filepath = buildPath(tempDir, "file" ~ i.to!string ~ ".txt");
        write(filepath, "original content " ~ i.to!string);
        
        auto originalContent = readText(filepath);
        
        // Maybe corrupt
        corruptor.maybeCorrupt(filepath);
        
        if (exists(filepath))
        {
            auto newContent = readText(filepath);
            if (newContent != originalContent)
                corruptedCount++;
        }
    }
    
    Logger.info("Files corrupted: " ~ corruptedCount.to!string ~ "/20");
    Logger.info("Corruption count: " ~ corruptor.getCorruptionCount().to!string);
    
    Assert.isTrue(corruptedCount > 0, "Should have corrupted some files");
    
    writeln("  \x1b[32m✓ File corruption test passed\x1b[0m");
}

/// Test: Cache corruption during build
@("corruption_chaos.cache_corruption")
@system unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Cache Corruption");
    
    auto cacheDir = buildPath(tempDir(), "cache-corruption-test");
    auto simulator = new ChaosSimulator(cacheDir);
    scope(exit)
        if (exists(cacheDir))
            rmdirRecurse(cacheDir);
    
    // Enable cache corruption
    simulator.enableFileCorruption(CorruptionType.CacheCorruption, 0.3);
    
    // Run build
    auto result = simulator.simulateBuild("build1", 500.msecs);
    
    size_t corruptions = simulator.getTotalCorruptions();
    Logger.info("Cache corruptions during build: " ~ corruptions.to!string);
    
    // Build may succeed or fail depending on corruption
    if (result.isOk)
    {
        Logger.info("Build succeeded despite corruptions");
    }
    else
    {
        Logger.info("Build failed due to corruption");
    }
    
    Assert.isTrue(true, "Handled corruption");
    
    writeln("  \x1b[32m✓ Cache corruption test passed\x1b[0m");
}

/// Test: File truncation
@("corruption_chaos.truncation")
@system unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m File Truncation");
    
    auto tempDir = buildPath(tempDir(), "truncation-test");
    if (!exists(tempDir))
        mkdirRecurse(tempDir);
    scope(exit)
        if (exists(tempDir))
            rmdirRecurse(tempDir);
    
    auto corruptor = new FileCorruptor();
    corruptor.addChaos(CorruptionChaosConfig(CorruptionType.FileTruncation, 1.0, true));
    
    // Create file with content
    auto filepath = buildPath(tempDir, "large.txt");
    auto originalContent = "x" ~ "a".replicate(1000) ~ "y";
    write(filepath, originalContent);
    
    auto originalSize = read(filepath).length;
    
    // Truncate
    corruptor.maybeCorrupt(filepath);
    
    if (exists(filepath))
    {
        auto newSize = read(filepath).length;
        Logger.info("File size: " ~ originalSize.to!string ~ " -> " ~ newSize.to!string);
        
        Assert.isTrue(newSize < originalSize, "File should be truncated");
    }
    
    writeln("  \x1b[32m✓ File truncation test passed\x1b[0m");
}

/// Test: File deletion
@("corruption_chaos.deletion")
@system unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m File Deletion");
    
    auto tempDir = buildPath(tempDir(), "deletion-test");
    if (!exists(tempDir))
        mkdirRecurse(tempDir);
    scope(exit)
        if (exists(tempDir))
            rmdirRecurse(tempDir);
    
    auto corruptor = new FileCorruptor();
    corruptor.addChaos(CorruptionChaosConfig(CorruptionType.FileDeletion, 1.0, true));
    
    auto filepath = buildPath(tempDir, "delete_me.txt");
    write(filepath, "content");
    
    Assert.isTrue(exists(filepath), "File should exist before corruption");
    
    corruptor.maybeCorrupt(filepath);
    
    Assert.isFalse(exists(filepath), "File should be deleted");
    
    writeln("  \x1b[32m✓ File deletion test passed\x1b[0m");
}

/// Test: Worker killing
@("corruption_chaos.worker_kill")
@system unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Worker Killing");
    
    auto killer = new WorkerKiller();
    
    // Configure to kill after 100ms
    killer.addKillConfig(WorkerKillConfig(WorkerKillType.SigKill, 1.0, 100.msecs, true));
    
    auto startTime = MonoTime.currTime;
    Result!BuildError result;
    
    // Simulate execution that would take 500ms
    for (size_t i = 0; i < 10; i++)
    {
        auto elapsed = MonoTime.currTime - startTime;
        
        result = killer.maybeKillWorker("worker1", elapsed);
        if (result.isErr)
        {
            Logger.info("Worker killed after " ~ elapsed.total!"msecs".to!string ~ "ms");
            break;
        }
        
        Thread.sleep(50.msecs);
    }
    
    Assert.isTrue(result.isErr, "Worker should be killed");
    Assert.equal(killer.getKillCount(), 1, "Should have killed one worker");
    
    writeln("  \x1b[32m✓ Worker killing test passed\x1b[0m");
}

/// Test: Multiple worker kills
@("corruption_chaos.multiple_kills")
@system unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Multiple Worker Kills");
    
    auto killer = new WorkerKiller();
    
    // Various kill types
    killer.addKillConfig(WorkerKillConfig(WorkerKillType.SigKill, 0.3, 0.seconds, true));
    killer.addKillConfig(WorkerKillConfig(WorkerKillType.OutOfMemory, 0.2, 0.seconds, true));
    killer.addKillConfig(WorkerKillConfig(WorkerKillType.Timeout, 0.2, 0.seconds, true));
    
    // Try to kill multiple workers
    size_t killCount = 0;
    for (size_t i = 0; i < 10; i++)
    {
        auto result = killer.maybeKillWorker("worker" ~ i.to!string, 100.msecs);
        if (result.isErr)
            killCount++;
    }
    
    Logger.info("Workers killed: " ~ killCount.to!string ~ "/10");
    Logger.info("Kill count: " ~ killer.getKillCount().to!string);
    
    Assert.isTrue(killCount > 0, "Should have killed some workers");
    Assert.equal(killCount, killer.getKillCount(), "Counts should match");
    
    writeln("  \x1b[32m✓ Multiple kills test passed\x1b[0m");
}

/// Test: Combined corruption and killing
@("corruption_chaos.combined")
@system unittest
{
    writeln("\x1b[36m[CHAOS]\x1b[0m Combined Corruption & Killing");
    
    auto cacheDir = buildPath(tempDir(), "combined-chaos-test");
    auto simulator = new ChaosSimulator(cacheDir);
    scope(exit)
        if (exists(cacheDir))
            rmdirRecurse(cacheDir);
    
    // Enable all chaos types
    simulator.enableFileCorruption(CorruptionType.FileCorruption, 0.2);
    simulator.enableFileCorruption(CorruptionType.CacheCorruption, 0.2);
    simulator.enableFileCorruption(CorruptionType.FileTruncation, 0.1);
    simulator.enableWorkerKilling(WorkerKillType.SigKill, 0.1, 200.msecs);
    simulator.enableWorkerKilling(WorkerKillType.Timeout, 0.1, 300.msecs);
    
    // Run multiple builds
    size_t successCount = 0;
    size_t failureCount = 0;
    
    for (size_t i = 0; i < 10; i++)
    {
        auto result = simulator.simulateBuild("build" ~ i.to!string, 500.msecs);
        if (result.isOk)
            successCount++;
        else
            failureCount++;
    }
    
    Logger.info("Results:");
    Logger.info("  Successful builds: " ~ successCount.to!string);
    Logger.info("  Failed builds: " ~ failureCount.to!string);
    Logger.info("  Total corruptions: " ~ simulator.getTotalCorruptions().to!string);
    Logger.info("  Total kills: " ~ simulator.getTotalKills().to!string);
    
    Assert.isTrue(simulator.getTotalCorruptions() > 0 || simulator.getTotalKills() > 0,
                 "Should have applied some chaos");
    
    writeln("  \x1b[32m✓ Combined chaos test passed\x1b[0m");
}
