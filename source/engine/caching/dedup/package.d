/// Content-Addressable Storage Deduplication
/// 
/// Provides 30-70% storage reduction on large monorepos through:
/// - Content-addressed blob storage (CAS)
/// - Manifest-based action results referencing blobs
/// - Reference counting for safe garbage collection
/// - SQLite-backed blob index for efficient queries
/// 
/// Architecture:
/// ```
/// ┌─────────────────────────────────────────────────────────────┐
/// │                      DedupStore                              │
/// │  ┌─────────────┐   ┌─────────────┐   ┌─────────────────┐   │
/// │  │  Manifests  │──▶│ DedupEngine │──▶│      CAS        │   │
/// │  │ (metadata)  │   │ (ref count) │   │ (blob storage)  │   │
/// │  └─────────────┘   └─────────────┘   └─────────────────┘   │
/// │         │                 │                  │              │
/// │         └─────────────────┼──────────────────┘              │
/// │                           ▼                                 │
/// │                    ┌─────────────┐                          │
/// │                    │  BlobIndex  │                          │
/// │                    │  (SQLite)   │                          │
/// │                    └─────────────┘                          │
/// └─────────────────────────────────────────────────────────────┘
/// ```
/// 
/// Usage:
/// ```d
/// import engine.caching.dedup;
/// 
/// // Create deduplicated store
/// auto store = new DedupStore(".builder-cache/dedup");
/// 
/// // Store action outputs (auto-deduplicates)
/// auto outputs = [cast(ubyte[])"content1", cast(ubyte[])"content2"];
/// auto paths = ["out/file1.o", "out/file2.o"];
/// auto hash = store.put("action:123", outputs, paths, "inputs-hash");
/// 
/// // Retrieve action result
/// auto manifest = store.get("action:123");
/// 
/// // Materialize outputs
/// auto files = store.materialize("action:123");
/// foreach (f; files)
///     std.file.write(f.path, f.data);
/// 
/// // Check deduplication stats
/// auto stats = store.getStats();
/// writefln("Saved %.1f%% storage", stats.dedup.efficiency());
/// ```
module engine.caching.dedup;

public import engine.caching.dedup.dedup;
public import engine.caching.dedup.manifest;
public import engine.caching.dedup.store;
public import engine.caching.dedup.blobindex;

