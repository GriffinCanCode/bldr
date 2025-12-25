module infrastructure.analysis.tracking.interface_;

import infrastructure.analysis.tracking.tracker : FileState, ChangeResult;
import infrastructure.errors;

/// Interface for file change tracking implementations
/// Enables dependency injection and testing
interface IFileChangeTracker
{
    /// Initialize tracking for a file
    VoidBuildResult track(string path) @system;
    
    /// Track multiple files (batch operation)
    VoidBuildResult trackBatch(string[] paths) @system;
    
    /// Check if file has changed since last track
    /// Returns: ChangeResult with change status and content hash
    BuildResult!ChangeResult checkChange(string path) @system;
    
    /// Check multiple files for changes (batch operation)
    BuildResult!(ChangeResult[string]) checkChanges(string[] paths) @system;
    
    /// Get current state for a file
    BuildResult!(FileState*) getState(string path) @system;
    
    /// Update state for a file (after analysis)
    VoidBuildResult updateState(string path, string contentHash) @system;
    
    /// Remove file from tracking
    void untrack(string path) @system;
    
    /// Get all tracked files
    string[] getTrackedFiles() @system;
    
    /// Clear all tracking state
    void clear() @system;
    
    /// Get statistics
    struct Stats
    {
        size_t trackedFiles;
        size_t metadataChecks;
        size_t contentHashChecks;
        size_t changesDetected;
        float fastPathRate;
    }
    
    Stats getStats() const @system;
}

