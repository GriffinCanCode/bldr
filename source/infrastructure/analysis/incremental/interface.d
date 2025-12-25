module infrastructure.analysis.incremental.interface_;

import infrastructure.analysis.targets.types;
import infrastructure.config.schema.schema;
import infrastructure.errors;

/// Interface for incremental analysis implementations
/// Enables dependency injection and testing
interface IIncrementalAnalyzer
{
    /// Analyze target with incremental optimization
    /// Returns: Result with TargetAnalysis
    BuildResult!TargetAnalysis analyzeTarget(ref Target target) @system;
    
    /// Initialize tracking for all sources in workspace
    VoidBuildResult initialize(WorkspaceConfig config) @system;
    
    /// Invalidate cache for specific files
    void invalidate(string[] paths) @system;
    
    /// Clear all caches and tracking
    void clear() @system;
    
    /// Get combined statistics
    struct Stats
    {
        size_t totalFiles;
        size_t filesReanalyzed;
        size_t filesCached;
        float cacheHitRate;
        float reductionRate;
        
        // Nested stats from dependencies
        struct CacheStats
        {
            size_t hits;
            size_t misses;
            size_t stores;
            float hitRate;
            size_t totalQueries;
        }
        
        struct TrackerStats
        {
            size_t trackedFiles;
            size_t metadataChecks;
            size_t contentHashChecks;
            size_t changesDetected;
            float fastPathRate;
        }
        
        CacheStats cacheStats;
        TrackerStats trackerStats;
    }
    
    Stats getStats() @system;
    
    /// Print statistics
    void printStats() @system;
}

