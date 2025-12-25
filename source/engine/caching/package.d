module engine.caching;

/// Builder caching system
/// 
/// This module provides a comprehensive multi-tier caching system for
/// build artifacts, actions, and remote distribution.
/// 
/// ## Architecture
/// 
/// The caching system is organized into components:
/// 
/// ### 1. Coordinator (`caching.coordinator`)
/// Unified orchestration of all caching tiers with event emission,
/// garbage collection, and content-addressable storage.
/// 
/// ### 2. Index (`caching.index`)
/// SQLite-backed metadata index providing:
/// - Efficient partial queries for cache introspection
/// - LRU tracking without loading full cache
/// - WAL-based crash recovery
/// - Unified statistics across all cache types
/// 
/// ### 3. Target-Level Caching (`caching.targets`)
/// Caches complete build outputs for each target based on source and
/// dependency hashes. Primary caching mechanism.
/// 
/// ### 4. Action-Level Caching (`caching.actions`)
/// Finer-grained caching for individual build actions (compile,
/// link, codegen, etc.). Enables partial rebuilds.
/// 
/// ### 5. Cache Policies (`caching.policies`)
/// Manages cache eviction using LRU, age-based, and size-based strategies.
/// Now powered by SQLite index for efficient selection.
/// 
/// ### 6. Distributed Caching (`caching.distributed`)
/// Coordinates local and remote cache tiers for team collaboration.
/// 
/// ### 7. Storage (`caching.storage`)
/// Content-addressable storage with deduplication and garbage collection.
/// 
/// ### 8. Metrics (`caching.metrics`)
/// Real-time cache metrics collection and statistics.
/// 
/// ### 9. Events (`caching.events`)
/// Cache events for telemetry integration.
/// 
/// ## Usage
/// 
/// ### With Coordinator (Recommended)
/// ```d
/// import core.caching;
/// 
/// auto coordinator = new CacheCoordinator(".builder-cache", publisher);
/// 
/// if (!coordinator.isCached(targetId, sources, deps)) {
///     // Perform build
///     coordinator.update(targetId, sources, deps, outputHash);
/// }
/// 
/// coordinator.flush();
/// coordinator.close();
/// ```
/// 
/// ### Direct Cache Usage
/// ```d
/// import core.caching;
/// 
/// auto cache = new BuildCache();
/// 
/// if (!cache.isCached(targetId, sources, deps)) {
///     // Perform build
///     cache.update(targetId, sources, deps, outputHash);
/// }
/// 
/// cache.flush();
/// cache.close();
/// ```

// Coordinator (unified interface)
public import engine.caching.coordinator;

// SQLite-backed index (metadata, queries, crash recovery)
public import engine.caching.index;

// Core caching components
public import engine.caching.targets;
public import engine.caching.actions;
public import engine.caching.policies;
public import engine.caching.distributed;

// Module interface caching (C++20 BMI)
public import engine.caching.modules;

// Storage layer
public import engine.caching.storage;

// Content deduplication
public import engine.caching.dedup;

// Metrics and events
public import engine.caching.metrics;
public import engine.caching.events;
