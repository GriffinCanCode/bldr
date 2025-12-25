module infrastructure.di;

/// Dependency Injection Infrastructure
/// 
/// Provides formalized service container pattern for testability:
/// - IServiceContainer: Interface for all service access
/// - NullServiceContainer: No-op implementation for testing
/// - MockServiceContainer: Configurable mock for integration tests
/// - ServiceScope: RAII-style lifetime management
/// 
/// Usage:
///   // Production code
///   void build(IServiceContainer services) {
///       if (services.hasTracing)
///           services.tracer.startSpan("build");
///   }
///   
///   // Test code
///   auto services = new MockServiceContainer();
///   build(services);

public import infrastructure.di.container :
    IServiceContainer,
    NullServiceContainer,
    MockServiceContainer,
    ServiceScope;

