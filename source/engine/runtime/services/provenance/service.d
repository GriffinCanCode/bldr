/**
 * Provenance Service
 * 
 * Service layer for build provenance generation, integrating with
 * the dependency injection architecture. Provides thread-safe
 * provenance collection during parallel builds.
 */
module engine.runtime.services.provenance.service;

import engine.provenance;
import infrastructure.errors;

/// Provenance service interface
interface IProvenanceService
{
    /// Begin collecting provenance for a build
    void begin(bool hermetic = false) @system;
    
    /// Record input material
    void recordMaterial(string path) @system;
    
    /// Record output artifact
    void recordOutput(string path, string name = "") @system;
    
    /// Record build parameter
    void recordParameter(string key, string value) @system;
    
    /// Finalize and get provenance
    BuildResult!BuildProvenance complete() @system;
    
    /// Check if provenance collection is active
    bool isActive() const @system;
    
    /// Get configuration
    ProvenanceConfig config() const @safe;
}

/// Default provenance service implementation
final class ProvenanceService : IProvenanceService
{
    private ProvenanceCollector collector;
    private ProvenanceConfig _config;
    private string workspace;
    
    /// Create service with configuration
    this(ProvenanceConfig config = ProvenanceConfig.init, string workspace = ".") @system
    {
        this._config = config;
        this.workspace = workspace;
        this.collector = new ProvenanceCollector(config);
    }
    
    /// Create from environment
    static ProvenanceService fromEnvironment(string workspace = ".") @system
    {
        return new ProvenanceService(ProvenanceConfig.fromEnvironment(), workspace);
    }
    
    /// Begin collecting
    void begin(bool hermetic = false) @system
    {
        if (_config.enabled)
            collector.begin(hermetic);
    }
    
    /// Record material
    void recordMaterial(string path) @system
    {
        if (_config.enabled)
            collector.recordMaterial(path);
    }
    
    /// Record output
    void recordOutput(string path, string name = "") @system
    {
        if (_config.enabled)
            collector.recordOutput(path, name);
    }
    
    /// Record parameter
    void recordParameter(string key, string value) @system
    {
        if (_config.enabled)
            collector.recordParameter(key, value);
    }
    
    /// Complete and get provenance
    BuildResult!BuildProvenance complete() @system
    {
        if (!_config.enabled)
            return Err!(BuildProvenance, BuildError)(
                new SystemError("Provenance disabled", ErrorCode.BuildCancelled));
        
        return collector.complete();
    }
    
    /// Check if active
    bool isActive() const @system
    {
        return _config.enabled && collector.isActive();
    }
    
    /// Get config
    ProvenanceConfig config() const @safe
    {
        return _config;
    }
    
    /// Sign and export provenance to file
    VoidBuildResult exportToFile(const ref BuildProvenance prov, string outputPath) @system
    {
        return ProvenanceExporter.writeToFile(prov, outputPath, _config.signProvenance, workspace);
    }
}

/// Null provenance service (disabled)
final class NullProvenanceService : IProvenanceService
{
    private static ProvenanceConfig nullConfig;
    
    static this()
    {
        nullConfig.enabled = false;
    }
    
    void begin(bool) @system {}
    void recordMaterial(string) @system {}
    void recordOutput(string, string = "") @system {}
    void recordParameter(string, string) @system {}
    
    BuildResult!BuildProvenance complete() @system
    {
        return Err!(BuildProvenance, BuildError)(
            new SystemError("Provenance disabled", ErrorCode.BuildCancelled));
    }
    
    bool isActive() const @system { return false; }
    ProvenanceConfig config() const @safe { return nullConfig; }
}


