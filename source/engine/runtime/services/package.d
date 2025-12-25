module engine.runtime.services;

/// Runtime Services Module
/// 
/// This module provides the core service infrastructure for the Builder build system.
/// It implements a modular, dependency-injection based architecture that decouples
/// components and enables testing.
/// 
/// Architecture:
///   - Service Container: Centralized DI container (BuildServices)
///   - Caching: Unified cache abstraction (CacheService)
///   - Observability: Events, tracing, and logging (ObservabilityService)
///   - Resilience: Retry and checkpoint/resume (ResilienceService)
///   - Registry: Language handler management (HandlerRegistry)
///   - Scheduling: Parallel task execution (SchedulingService)
/// 
/// Usage:
///   import engine.runtime.services;
///   
///   auto services = ServiceFactory.createProduction(config, options);
///   auto engine = services.createEngine(graph);
///   auto result = engine.execute();
///   services.shutdown();

// Container and factory
public import engine.runtime.services.container : 
    BuildServices, 
    ServiceFactory;

// Caching service
public import engine.runtime.services.caching : 
    ICacheService, 
    CacheService,
    ServiceCacheStats;

// Observability service
public import engine.runtime.services.observability : 
    IObservabilityService, 
    ObservabilityService,
    NullObservabilityService;

// Resilience service
public import engine.runtime.services.resilience : 
    IResilienceService, 
    ResilienceService,
    NullResilienceService;

// Handler registry
public import engine.runtime.services.registry : 
    IHandlerRegistry, 
    HandlerRegistry,
    NullHandlerRegistry;

// Scheduling service
public import engine.runtime.services.scheduling : 
    ISchedulingService, 
    SchedulingService,
    SchedulingMode,
    SchedulingStats,
    NodeBuildResult;

// Provenance service
public import engine.runtime.services.provenance :
    IProvenanceService,
    ProvenanceService,
    NullProvenanceService;

// Speculation service (with predictive execution for large monorepos)
public import engine.runtime.services.speculation :
    // Core service
    ISpeculationService,
    SpeculationService,
    SpeculationPolicy,
    SpeculativeTask,
    SpeculativeStatus,
    SpeculationStats,
    createSpeculationService,
    // Executor
    SpeculationExecutor,
    SpeculationExecutorStats,
    createSpeculationExecutor,
    createPredictiveSpeculationExecutor,
    // Predictor
    ChangePredictor,
    ChangeProbability,
    PredictorConfig,
    PredictorState,
    PredictorStats,
    // History
    HistoryTracker,
    HistoryConfig,
    HistoryStats,
    ChangeEvent,
    ChangeType,
    ChangeCorrelation,
    BuildSession,
    // Engine
    SpeculativeEngine,
    SpeculativeResult,
    EngineConfig,
    EngineStats,
    createSpeculativeEngine;
