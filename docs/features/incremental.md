# Incremental Dependency Analysis

**Module:** `infrastructure.analysis.incremental`

## Overview

Incremental dependency analysis reduces build analysis time by reusing cached results for unchanged files. Only modified files are reanalyzed; cached results serve unchanged files.

## Architecture

### Components

#### 1. IncrementalAnalyzer (`analysis/incremental/analyzer.d`)

Coordinates change tracking and selective reanalysis via dependency injection:

```d
// Create dependencies
auto analysisCache = new AnalysisCache(".builder-cache/analysis");
auto changeTracker = new FileChangeTracker();

// Inject into analyzer
auto analyzer = new IncrementalAnalyzer(config, analysisCache, changeTracker);
analyzer.initialize(config);

// Analyze target (uses cache automatically)
auto result = analyzer.analyzeTarget(target);
```

**Algorithm:**
1. Check which files have changed via `FileChangeTracker`
2. Load cached analysis for unchanged files from `AnalysisCache`
3. Classify files as changed or unchanged
4. Return cached analyses; caller handles changed files

#### 2. AnalysisCache (`analysis/caching/store.d`)

Content-addressable storage for `FileAnalysis` results:

```d
// Store analysis indexed by content hash
cache.put(contentHash, fileAnalysis);

// Retrieve cached analysis
auto result = cache.get(contentHash);
```

**Implementation:**
- Uses shared `ContentAddressableStorage` for deduplication
- Binary serialization for compact storage
- Thread-safe via internal mutex
- Statistics: hits, misses, stores, hit rate

#### 3. FileChangeTracker (`analysis/tracking/tracker.d`)

Detects file changes using two-tier validation:

```d
// Initialize tracking
tracker.track(filePath);

// Check for changes
auto result = tracker.checkChange(filePath);
if (result.hasChanged) {
    // File modified - reanalyze
} else {
    // Unchanged - use cached analysis
}
```

**Two-Tier Validation:**
- **Fast path:** Metadata hash (mtime + size via `FastHash.hashMetadata`)
- **Slow path:** Content hash (full file via `FastHash.hashFile`) only when metadata differs

Change detection results include:
- `ChangeKind.Unchanged` - No change detected
- `ChangeKind.Modified` - Content changed
- `ChangeKind.New` - File newly tracked
- `ChangeKind.Deleted` - File removed

#### 4. AnalysisWatcher (`analysis/incremental/watcher.d`)

Proactively invalidates cache when files change:

```d
auto watcher = new AnalysisWatcher(analyzer, config);
watcher.start();  // Start watching with 200ms debounce
```

**Features:**
- Uses native file watcher with recursive monitoring
- Integrates with `IncrementalParseAdapter` for efficient re-parsing
- Filters events to source files only
- Automatic cache invalidation

## Usage

### Basic (Automatic)

Incremental analysis is enabled by default:

```bash
# First build: Full analysis
bldr build //my:target

# Subsequent builds: Incremental
bldr build //my:target
```

### With Watch Mode

```bash
bldr build --watch //my:target
```

Combines file watching with incremental analysis for minimal rebuild latency.

### Programmatic Usage

```d
import infrastructure.analysis.incremental;
import infrastructure.analysis.caching.store;
import infrastructure.analysis.tracking.tracker;

// Create and inject dependencies
auto cache = new AnalysisCache(".builder-cache/analysis");
auto tracker = new FileChangeTracker();
auto analyzer = new IncrementalAnalyzer(config, cache, tracker);

// Initialize
auto result = analyzer.initialize(config);
if (result.isErr)
    writeln("Initialization failed");

// Analyze
auto analysisResult = analyzer.analyzeTarget(target);

// Optional: Start watcher
auto watcher = new AnalysisWatcher(analyzer, config);
watcher.start();
```

## Cache Invalidation

Cache entries are invalidated when:

1. **Content changes** - Content hash differs
2. **File deleted** - Tracked via `ChangeKind.Deleted`
3. **File created** - New file returns `ChangeKind.New`
4. **Manual clear** - `analyzer.clear()` or `cache.clear()`

Cache is **not** invalidated for:
- Metadata-only changes (e.g., `touch` without content change)
- Unrelated file modifications

## Statistics

```d
auto stats = analyzer.getStats();
writefln("Cache hit rate: %.1f%%", stats.cacheHitRate);
writefln("Work reduction: %.1f%%", stats.reductionRate);
writefln("Fast path rate: %.1f%%", stats.trackerStats.fastPathRate);

// Print formatted statistics
analyzer.printStats();
```

**Output:**
```
╔════════════════════════════════════════════════════════════╗
║       Incremental Dependency Analysis Statistics          ║
╠════════════════════════════════════════════════════════════╣
║  Total Files:          1,000                               ║
║  Files Reanalyzed:       10                                ║
║  Files from Cache:      990                                ║
║  Cache Hit Rate:        99.0%                              ║
║  Work Reduction:        99.0%                              ║
╠════════════════════════════════════════════════════════════╣
║  Metadata Checks:      1,000                               ║
║  Content Hash Checks:    10                                ║
║  Fast Path Rate:        99.0%                              ║
║  Changes Detected:       10                                ║
╚════════════════════════════════════════════════════════════╝
```

## Integration with Build Caches

Builder uses multiple caching layers:

| Layer | Location | Purpose |
|-------|----------|---------|
| Graph Cache | `core/graph/cache.d` | Dependency graph topology |
| Analysis Cache | `analysis/caching/store.d` | Per-file analysis results |
| Action Cache | `core/caching/actions/` | Build action outputs |
| Target Cache | `core/caching/targets/` | Target execution results |

**Invalidation Flow:**
- File changes → invalidate Analysis Cache
- Builderfile changes → invalidate Graph Cache
- Source changes → invalidate dependent Action Caches

## Serialization Format

Analysis cache uses binary serialization:

```
Version (1 byte)
Path (length-prefixed string)
Content Hash (length-prefixed string)
Has Errors (1 byte)
Errors Count (4 bytes, big-endian)
Errors (array of length-prefixed strings)
Imports Count (4 bytes, big-endian)
Imports (array):
  - Module Name (length-prefixed string)
  - Import Kind (1 byte)
  - Location File (length-prefixed string)
  - Line (8 bytes, big-endian)
  - Column (8 bytes, big-endian)
```

## Interface Definitions

### IIncrementalAnalyzer

```d
interface IIncrementalAnalyzer
{
    BuildResult!TargetAnalysis analyzeTarget(ref Target target);
    VoidBuildResult initialize(WorkspaceConfig config);
    void invalidate(string[] paths);
    void clear();
    Stats getStats();
    void printStats();
}
```

### IAnalysisCache

```d
interface IAnalysisCache
{
    BuildResult!(FileAnalysis*) get(string contentHash);
    VoidBuildResult put(string contentHash, const ref FileAnalysis analysis);
    bool has(string contentHash);
    BuildResult!(FileAnalysis*[string]) getBatch(string[] contentHashes);
    VoidBuildResult putBatch(FileAnalysis[string] analyses);
    void clear();
    Stats getStats() const;
}
```

### IFileChangeTracker

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
```

## See Also

- [Caching Architecture](../architecture/cachedesign.md)
- [Watch Mode](watch.md)
- [Parse Cache](parsecache.md)
