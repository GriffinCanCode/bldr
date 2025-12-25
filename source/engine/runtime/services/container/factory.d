module engine.runtime.services.container.factory;

import engine.runtime.services.container.services : BuildServices;
import infrastructure.config.schema.schema : WorkspaceConfig, BuildOptions;
import infrastructure.config.parsing.parser : ConfigParser;
import infrastructure.analysis.inference.analyzer : DependencyAnalyzer;
import engine.caching.targets.cache : BuildCache;
import frontend.cli.events.events : EventPublisher;
import infrastructure.errors;

/// Factory methods for creating services in different contexts
struct ServiceFactory
{
    /// Create services for production use
    static BuildServices createProduction(WorkspaceConfig config, BuildOptions options)
    {
        return new BuildServices(config, options);
    }
    
    /// Create services with workspace auto-detection
    static BuildResult!BuildServices createFromWorkspace(
        string workspaceRoot,
        BuildOptions options)
    {
        auto configResult = ConfigParser.parseWorkspace(workspaceRoot);
        if (configResult.isErr)
        {
            return BuildResult!BuildServices.err(configResult.unwrapErr());
        }
        
        auto config = configResult.unwrap();
        auto services = new BuildServices(config, options);
        return BuildResult!BuildServices.ok(services);
    }
    
    /// Create services for testing with mocks
    static BuildServices createForTesting(
        WorkspaceConfig config,
        DependencyAnalyzer analyzer,
        BuildCache cache,
        EventPublisher publisher)
    {
        return new BuildServices(config, analyzer, cache, publisher, null);
    }
}

