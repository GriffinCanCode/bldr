module infrastructure.errors.codes.category;

/// Error category hierarchy for systematic classification
/// Each category represents a distinct error domain with specific handling strategies
enum ErrorCategory
{
    Build,       /// Build execution errors (compilation, linking, output generation)
    Parse,       /// Configuration parsing errors (syntax, structure, format)
    Analysis,    /// Dependency analysis errors (resolution, cycles, missing deps)
    Cache,       /// Cache operation errors (local and remote cache)
    IO,          /// File system errors (read, write, permissions)
    Graph,       /// Dependency graph errors (topology, cycles, traversal)
    Language,    /// Language handler errors (compiler, syntax, toolchain)
    System,      /// System-level errors (process, memory, threads)
    Internal,    /// Internal/unexpected errors (assertions, unreachable code)
    Plugin,      /// Plugin system errors (loading, protocol, execution)
    LSP,         /// LSP server errors (protocol, document handling)
    Watch,       /// Watch mode errors (file system monitoring)
    Config,      /// Configuration/Validation errors (schema, values)
    Network,     /// Network communication errors (HTTP, gRPC, sockets)
    Repository,  /// External repository errors (fetch, verify, extract)
    Distributed, /// Distributed build errors (coordinator, worker, scheduling)
    Telemetry,   /// Observability errors (metrics, tracing, logging)
    Security,    /// Security errors (authentication, authorization, signatures)
    Toolchain,   /// Toolchain management errors (discovery, versioning)
    Migration,   /// Migration/conversion errors (from other build systems)
}

/// Get human-readable category name
string categoryName(ErrorCategory cat) pure nothrow @safe
{
    final switch (cat)
    {
        case ErrorCategory.Build:       return "Build";
        case ErrorCategory.Parse:       return "Parse";
        case ErrorCategory.Analysis:    return "Analysis";
        case ErrorCategory.Cache:       return "Cache";
        case ErrorCategory.IO:          return "I/O";
        case ErrorCategory.Graph:       return "Graph";
        case ErrorCategory.Language:    return "Language";
        case ErrorCategory.System:      return "System";
        case ErrorCategory.Internal:    return "Internal";
        case ErrorCategory.Plugin:      return "Plugin";
        case ErrorCategory.LSP:         return "LSP";
        case ErrorCategory.Watch:       return "Watch";
        case ErrorCategory.Config:      return "Config";
        case ErrorCategory.Network:     return "Network";
        case ErrorCategory.Repository:  return "Repository";
        case ErrorCategory.Distributed: return "Distributed";
        case ErrorCategory.Telemetry:   return "Telemetry";
        case ErrorCategory.Security:    return "Security";
        case ErrorCategory.Toolchain:   return "Toolchain";
        case ErrorCategory.Migration:   return "Migration";
    }
}

/// Get category documentation URL
string categoryDocsUrl(ErrorCategory cat) pure nothrow @safe
{
    final switch (cat)
    {
        case ErrorCategory.Build:       return "docs/user-guides/examples.md";
        case ErrorCategory.Parse:       return "docs/architecture/dsl.md";
        case ErrorCategory.Analysis:    return "docs/features/incremental-builds.md";
        case ErrorCategory.Cache:       return "docs/features/caching.md";
        case ErrorCategory.IO:          return "docs/user-guides/examples.md";
        case ErrorCategory.Graph:       return "docs/features/dependency-graph.md";
        case ErrorCategory.Language:    return "docs/features/languages.md";
        case ErrorCategory.System:      return "docs/architecture/hermetic.md";
        case ErrorCategory.Internal:    return "https://github.com/griffinstrier/bldr/issues";
        case ErrorCategory.Plugin:      return "docs/architecture/plugins.md";
        case ErrorCategory.LSP:         return "docs/user-guides/lsp.md";
        case ErrorCategory.Watch:       return "docs/user-guides/watch.md";
        case ErrorCategory.Config:      return "docs/architecture/dsl.md";
        case ErrorCategory.Network:     return "docs/features/remotecache.md";
        case ErrorCategory.Repository:  return "docs/features/repository-rules.md";
        case ErrorCategory.Distributed: return "docs/features/remote-execution.md";
        case ErrorCategory.Telemetry:   return "docs/features/observability.md";
        case ErrorCategory.Security:    return "docs/security/security.md";
        case ErrorCategory.Toolchain:   return "docs/features/toolchains.md";
        case ErrorCategory.Migration:   return "docs/user-guides/migration.md";
    }
}

