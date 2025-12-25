module infrastructure.config.caching;

/// Configuration caching for incremental DSL parsing
/// 
/// This module provides high-performance caching at two levels:
/// 
/// ## In-Memory Parse Cache (`parse.d`)
/// - Content-addressable AST storage with BLAKE3 hashing
/// - Two-tier validation (metadata + content)
/// - Binary AST serialization for speed
/// - Thread-safe concurrent access
/// - LRU eviction policy
/// 
/// ## SQLite Configuration Cache (`sqlite.d`)
/// - Persistent configuration storage across builds
/// - Prepared statements for sub-millisecond lookups
/// - WAL mode for crash recovery + concurrent reads
/// - Indexed queries by workspace, language, target type
/// - Denormalized target lookup for O(1) access
/// 
/// ## Usage
/// ```d
/// // Fast in-memory AST cache
/// auto parseCache = new ParseCache();
/// auto ast = parseCache.get(filePath);
/// 
/// // Persistent SQLite config cache
/// auto configIndex = new ConfigIndex(".builder-cache");
/// auto config = configIndex.getConfig(workspacePath);
/// auto targets = configIndex.getTargetsByLanguage(TargetLanguage.D);
/// ```

public import infrastructure.config.caching.storage;
public import infrastructure.config.caching.parse;
public import infrastructure.config.caching.sqlite;
