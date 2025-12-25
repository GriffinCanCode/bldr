# Incremental Dependency Analysis

## Problem

Traditional build systems reanalyze all source files on every build, even when only a few files have changed. For large projects this wastes significant time.

Example:
- Developer changes 1 file in a 10,000-file project
- Traditional: Reanalyzes all 10,000 files (~8.5 seconds)
- Incremental: Reanalyzes 1 file, reuses cache for 9,999 (~0.3 seconds)

## Design

### Core Insight

Analysis results are a pure function of file content:
```
analyze(content) → FileAnalysis
```

Since the same content always produces the same analysis:
1. Store analysis by content hash
2. Check if content changed before reanalyzing
3. Reuse cached analysis for unchanged content

This handles:
- **File renames**: Same content → same analysis
- **Deduplication**: Identical files share one analysis
- **Branch switches**: Unchanged files reuse cache

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│         IncrementalAnalyzer                                  │
│                                                              │
│  ┌──────────────────┐    ┌──────────────────┐              │
│  │ FileChangeTracker│◄───►│ AnalysisCache   │              │
│  │                  │    │                  │              │
│  │ • Metadata hash  │    │ • CAS storage    │              │
│  │ • Content hash   │    │ • Serialization  │              │
│  │ • Two-tier check │    │ • Deduplication  │              │
│  └──────────────────┘    └──────────────────┘              │
└─────────────────────────────────────────────────────────────┘
```

### Data Flow

```
Build Request
     │
     ▼
Collect Targets
     │
     ▼
Check File Changes (FileChangeTracker)
     │
     ├─ Metadata unchanged ─► Use Cached Analysis
     │
     └─ Metadata changed ─► Content Hash
                                │
                                ├─ Content unchanged ─► Use Cached Analysis
                                │
                                └─ Content changed ─► Analyze File ─► Cache Result
```

## Implementation

### FileChangeTracker

**Location**: `source/infrastructure/analysis/tracking/tracker.d`

Two-tier validation minimizes I/O:

```d
final class FileChangeTracker : IFileChangeTracker
{
    private FileState[string] states;
    
    BuildResult!ChangeResult checkChange(string path)
    {
        // Fast path: metadata check (~1μs)
        auto newMetadataHash = FastHash.hashMetadata(path);
        if (newMetadataHash == oldState.metadataHash)
            return unchanged;
        
        // Slow path: content hash (~50-800μs)
        auto newContentHash = FastHash.hashFile(path);
        if (newContentHash == oldState.contentHash)
        {
            // Content unchanged, just metadata (e.g., touch)
            updateMetadataHash();
            return unchanged;
        }
        
        // Content actually changed
        return changed;
    }
}
```

**FileState**:
```d
struct FileState
{
    string path;
    string metadataHash;  // Fast: mtime + size
    string contentHash;   // Slow: full content hash
    SysTime lastModified;
    ulong size;
    bool exists;
}
```

### IncrementalAnalyzer

**Location**: `source/infrastructure/analysis/incremental/analyzer.d`

Coordinates change tracking and caching:

```d
final class IncrementalAnalyzer : IIncrementalAnalyzer
{
    private IAnalysisCache cache;
    private IFileChangeTracker tracker;
    
    BuildResult!TargetAnalysis analyzeTarget(ref Target target)
    {
        // Check which files have changed
        auto changes = tracker.checkChanges(target.sources);
        
        // Classify files
        string[] changedFiles;
        string[] unchangedFiles;
        
        foreach (source; target.sources)
        {
            if (changes[source].hasChanged)
                changedFiles ~= source;
            else
                unchangedFiles ~= source;
        }
        
        // Reuse cached analysis for unchanged files
        FileAnalysis[] analyses;
        foreach (source; unchangedFiles)
        {
            auto cached = cache.get(changes[source].contentHash);
            if (cached.isOk)
                analyses ~= cached.unwrap();
            else
                changedFiles ~= source;  // Cache miss, reanalyze
        }
        
        // Return results (changed files handled by caller)
        return result;
    }
}
```

### Interfaces

Dependency injection for testability:

```d
interface IFileChangeTracker
{
    VoidBuildResult track(string path);
    VoidBuildResult trackBatch(string[] paths);
    BuildResult!ChangeResult checkChange(string path);
    BuildResult!(ChangeResult[string]) checkChanges(string[] paths);
    void untrack(string path);
    void clear();
    Stats getStats() const;
}

interface IAnalysisCache
{
    BuildResult!(FileAnalysis*) get(string contentHash);
    VoidBuildResult store(string contentHash, FileAnalysis analysis);
    void clear();
    Stats getStats();
}
```

## Performance

### Two-Tier Validation

| Check | Time | Usage |
|-------|------|-------|
| Metadata hash | ~1μs | Always |
| Content hash | ~50-800μs | Only if metadata changed |

95%+ of unchanged files detected by metadata alone.

### Expected Results

For a 10,000-file project:

| Scenario | Changed | Full Analysis | Incremental | Speedup |
|----------|---------|---------------|-------------|---------|
| No changes | 0 | 50s | 0.5s | 100x |
| Single file | 1 | 50s | 0.51s | 98x |
| Ten files | 10 | 50s | 0.55s | 91x |
| 1% changed | 100 | 50s | 1.0s | 50x |
| 10% changed | 1000 | 50s | 10s | 5x |

Typical development: 1-10 files changed → 50-90x speedup.

### Memory Overhead

Per-file overhead:
- Analysis cache entry: 200-500 bytes
- Tracker state: ~150 bytes
- Total per file: ~350-650 bytes

10,000 files: ~5-7 MB total.

## Key Design Decisions

### 1. Content-Addressable Storage

Store analysis by content hash, not path:
- Handles file renames automatically
- Natural deduplication
- Enables distributed caching

Trade-off: Requires content hash for lookup.

### 2. Two-Tier Validation

Check metadata first, content only if needed:
- Metadata check 100x faster than content hash
- Handles file touch without content change

Trade-off: Small chance of false positive on metadata collision.

### 3. Separate from Graph Cache

| Graph Cache | Analysis Cache |
|-------------|----------------|
| Entire dependency topology | Per-file analysis results |
| Invalidated by Builderfile changes | Invalidated by file content changes |
| Coarse-grained (whole graph) | Fine-grained (per file) |

More cache hits when graph changes but files don't.

### 4. BLAKE3 Content Hashing

Uses SIMD-accelerated BLAKE3:
- 3-5x faster than SHA-256
- Automatic hardware dispatch (AVX-512/AVX2/NEON)

### 5. No AST Caching

Cache analysis results (imports/deps), not ASTs:
- ASTs are language-specific and large
- Analysis results are compact (~200-500 bytes)
- AST parsing already fast (using regex)

## Statistics

The analyzer tracks:
- Files reanalyzed vs cached
- Cache hit rate
- Metadata vs content hash checks
- Work reduction percentage

```d
auto stats = analyzer.getStats();
writefln("Cache hit rate: %.1f%%", stats.cacheHitRate);
writefln("Work reduction: %.1f%%", stats.reductionRate);
writefln("Fast path rate: %.1f%%", stats.trackerStats.fastPathRate);
```

## Testing

Unit tests:
- FileChangeTracker: Metadata/content change detection, false positives
- AnalysisCache: Serialization, content-addressable lookup
- IncrementalAnalyzer: Cache hit/miss logic, partial reanalysis

Integration tests:
- Initial build (cache population)
- Rebuild (cache hit)
- File change (partial reanalysis)
- File rename (should reuse cache)
- Cache corruption (fallback to full analysis)

## Related Files

| File | Purpose |
|------|---------|
| `infrastructure/analysis/incremental/analyzer.d` | Main incremental analyzer |
| `infrastructure/analysis/tracking/tracker.d` | File change tracking |
| `infrastructure/analysis/caching/store.d` | Analysis cache storage |
| `infrastructure/analysis/caching/interface.d` | Cache interface |
| `infrastructure/analysis/tracking/interface.d` | Tracker interface |
| `infrastructure/utils/files/hash.d` | BLAKE3 hashing |
