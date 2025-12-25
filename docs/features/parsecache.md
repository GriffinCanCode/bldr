# Parse Cache

**Module:** `infrastructure.config.caching`

## Overview

The parse cache stores parsed ASTs (Abstract Syntax Trees) from Builderfiles, eliminating redundant lexing and parsing for unchanged files. This reduces build startup time for incremental builds.

## Design

### Why Cache AST?

Traditional systems cache build artifacts. Parse caching operates earlier:

1. **Finer Granularity** - Detect changes at syntax level before semantic analysis
2. **Context Independence** - AST is workspace-agnostic
3. **Clear Separation** - Parsing (syntax) and analysis (semantics) cached independently

### Cache Key

Content-addressable storage: `Key = FilePath + BLAKE3(FileContent)`

Benefits:
- Automatic invalidation on content changes
- No manual cache management
- Cross-machine reproducibility

## Architecture

### Components

**ParseCache** (`config/caching/parse.d`):
- In-memory LRU cache
- Optional disk persistence
- Two-tier validation
- Thread-safe via mutex

**ASTStorage** (`config/caching/storage.d`):
- Binary AST serialization
- SIMD-accelerated codec
- Version-aware format

### Cache Entry

```d
struct Entry
{
    BuildFile ast;           // Parsed AST
    string contentHash;      // BLAKE3 content hash
    string metadataHash;     // Fast hash (size + mtime)
    SysTime timestamp;       // Creation time
    SysTime lastAccess;      // LRU tracking
}
```

## Two-Tier Validation

### Tier 1: Metadata Hash (Fast Path)

```d
metadataHash = FastHash.hashMetadata(path);  // mtime + size
```

- Constant time (no file I/O for content)
- Catches most changes
- Checked first on every access

### Tier 2: Content Hash (Slow Path)

```d
contentHash = FastHash.hashFile(path);
```

- Reads entire file
- Computed only when metadata differs
- Guarantees correctness

### Validation Flow

1. Check metadata hash against cached value
2. If unchanged → return cached AST (fast path)
3. If changed → compute content hash
4. If content unchanged → update metadata, return cached AST
5. If content changed → cache miss, reparse

## Usage

### Basic Usage

```d
import infrastructure.config.caching.parse;

auto cache = new ParseCache(
    enableDiskCache: true,
    cacheDir: ".builder-cache/parse",
    maxEntries: 1000
);

// Get cached AST
auto cached = cache.get("path/to/Builderfile");
if (cached !is null) {
    // Cache hit - use cached AST
    return analyzeAST(*cached, workspaceRoot);
}

// Cache miss - parse and store
auto ast = parseToAST(source, filePath);
cache.put(filePath, ast);
```

### With parseDSL

```d
import infrastructure.config.parsing.unified;

auto result = parse(source, filePath, workspaceRoot, cache);
```

The `parse` function automatically checks cache before parsing.

### Configuration

```d
auto cache = new ParseCache(
    enableDiskCache: true,           // Persist across builds
    cacheDir: ".builder-cache/parse",
    maxEntries: 1000                 // LRU limit
);
```

### Environment Variable

```bash
export BUILDER_PARSE_CACHE=true   # Enable (default)
export BUILDER_PARSE_CACHE=false  # Disable for debugging
```

## Statistics

```d
auto stats = cache.getStats();
writefln("Hit rate: %.1f%%", stats.hitRate);
writefln("Fast path rate: %.1f%%", stats.metadataHitRate);

cache.printStats();
```

**Output:**
```
╔════════════════════════════════════════════════════════════╗
║           Parse Cache Statistics                           ║
╠════════════════════════════════════════════════════════════╣
║  Total Entries:           120                              ║
║  Cache Hits:              119                              ║
║  Cache Misses:              1                              ║
║  Hit Rate:               99.2%                             ║
╠════════════════════════════════════════════════════════════╣
║  Metadata Hits (fast):    118                              ║
║  Content Hashes (slow):     1                              ║
║  Fast Path Rate:         99.2%                             ║
╚════════════════════════════════════════════════════════════╝
```

## Binary Serialization

### Format

```
Version (1 byte)
FilePath (length-prefixed string)
Targets Count (4 bytes)
Target[]:
  - Name (length-prefixed string)
  - Line, Column (8 bytes each)
  - Fields Count (4 bytes)
  - Field[]:
    - Name (length-prefixed string)
    - Line, Column (8 bytes each)
    - Expression (recursive, tagged union)
```

### Implementation

**ASTStorage** provides:
- SIMD-accelerated serialization via `Codec`
- Compile-time code generation
- Varint encoding for efficiency
- Forward/backward compatibility via versioning

```d
// Serialize
ubyte[] data = ASTStorage.serialize(ast);

// Deserialize
BuildFile ast = ASTStorage.deserialize(data);
```

## Thread Safety

All operations are protected by internal mutex:
- Concurrent `get()` and `put()` operations are safe
- Lock contention minimal (fast critical sections)
- Suitable for parallel builds

## Memory Management

### In-Memory Cache

- LRU eviction when `maxEntries` exceeded
- Typical memory: ~5-20 KB per cached AST
- Automatic cleanup on scope exit

### Disk Cache

- Location: `.builder-cache/parse/`
- Persists across builds
- Loaded on initialization
- Flushed on `close()`

## Integration

### ConfigParser

```d
class ConfigParser
{
    private static ParseCache sharedParseCache;
    
    static Result!(WorkspaceConfig, BuildError) parseWorkspace(string root)
    {
        if (sharedParseCache is null)
            sharedParseCache = new ParseCache();
        
        foreach (buildFile; findBuildFiles(root))
        {
            auto result = parseBuildFile(buildFile, root);
            // ...
        }
        
        return Ok(config);
    }
    
    static void closeParseCache()
    {
        if (sharedParseCache !is null)
        {
            sharedParseCache.close();
            sharedParseCache = null;
        }
    }
}
```

### parseDSL Function

```d
BuildResult!BuildFile parse(
    string source,
    string filePath,
    string workspaceRoot,
    ParseCache cache = null)
{
    // Try cache first
    if (cache !is null)
    {
        auto cached = cache.get(filePath);
        if (cached !is null)
            return Ok!(BuildFile, BuildError)(*cached);
    }
    
    // Lex and parse
    auto lexResult = lex(source, filePath);
    if (lexResult.isErr) return lexResult.mapErr();
    
    auto parser = new UnifiedParser(lexResult.unwrap(), filePath, workspaceRoot);
    auto parseResult = parser.parse();
    
    // Cache result
    if (cache !is null && parseResult.isOk)
        cache.put(filePath, parseResult.unwrap());
    
    return parseResult;
}
```

## Cleanup

Always close the cache to ensure disk persistence:

```d
cache.close();

// Or via ConfigParser
ConfigParser.closeParseCache();
```

## Limitations

1. **In-memory only during build** - Disk cache loaded at start, flushed at end
2. **No compression** - Binary format uncompressed (speed over size)
3. **Single-machine** - Not distributed

## See Also

- [DSL Syntax](../architecture/DSL.md)
- [Cache Architecture](../architecture/cachedesign.md)
- [Incremental Analysis](incremental.md)

## Implementation Files

- `source/infrastructure/config/caching/parse.d` - ParseCache class
- `source/infrastructure/config/caching/storage.d` - ASTStorage serialization
- `source/infrastructure/config/caching/package.d` - Module exports
- `source/infrastructure/config/parsing/unified.d` - Integration with parse()
