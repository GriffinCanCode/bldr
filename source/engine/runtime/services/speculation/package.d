module engine.runtime.services.speculation;

/// Speculative Execution for Large Monorepo Optimization
/// 
/// ## Overview
/// Speculatively executes targets predicted to need rebuilding based on:
/// - **Change probability**: Bayesian model learning from historical patterns
/// - **Critical path analysis**: Prioritize targets that would delay the build
/// - **Co-change correlation**: Learn which files change together
/// - **Time patterns**: Adapt to developer work patterns
/// 
/// ## Key Differentiators for Large Monorepos
/// 
/// 1. **Predictive Speculation**: Uses machine learning to predict which targets
///    will need rebuilding, not just which are on the critical path
/// 
/// 2. **Background Workers**: Speculative builds run on dedicated threads,
///    not blocking the main build pipeline
/// 
/// 3. **Abort Semantics**: If inputs change during speculation, results are
///    automatically invalidated and discarded
/// 
/// 4. **Historical Learning**: The system learns from past builds to improve
///    prediction accuracy over time
/// 
/// ## Architecture
/// ```
/// ┌─────────────────────────────────────────────────────────────────┐
/// │                    SpeculationExecutor                           │
/// │  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────┐ │
/// │  │SpeculationService│───▶│SpeculativeEngine│───▶│   Workers   │ │
/// │  └────────┬────────┘    └────────┬────────┘    └─────────────┘ │
/// │           │                      │                              │
/// │  ┌────────▼────────┐    ┌────────▼────────┐                    │
/// │  │ ChangePredictor │    │ HistoryTracker  │                    │
/// │  │ - Bayesian model│    │ - Persistence   │                    │
/// │  │ - Co-change     │    │ - Sessions      │                    │
/// │  │ - Time patterns │    │ - Correlations  │                    │
/// │  └─────────────────┘    └─────────────────┘                    │
/// └─────────────────────────────────────────────────────────────────┘
/// ```
/// 
/// ## Usage
/// 
/// ### Basic Usage
/// ```d
/// import engine.runtime.services.speculation;
/// 
/// auto executor = createSpeculationExecutor(graph, scheduling);
/// executor.beginSpeculation();
/// 
/// // During build loop
/// if (auto result = executor.tryGetSpeculativeResult(targetId))
///     useResult(result.get());
/// else
///     buildNormally(targetId);
/// 
/// executor.shutdown();
/// ```
/// 
/// ### Predictive Mode (Recommended for Large Monorepos)
/// ```d
/// import engine.runtime.services.speculation;
/// 
/// // Create with predictive engine
/// auto executor = createPredictiveSpeculationExecutor(
///     graph, scheduling, 
///     SpeculationPolicy.aggressive(),
///     ".builder-cache/speculation"
/// );
/// 
/// // Set build executor for background workers
/// executor.setNodeExecutor((node) { return buildTarget(node); });
/// 
/// // Start background speculation
/// executor.startEngine();
/// executor.beginSpeculation();
/// 
/// // ... build loop ...
/// 
/// executor.shutdown();  // Saves learned patterns
/// ```
/// 
/// ### Recording Changes (for Learning)
/// ```d
/// // Record when files change (e.g., from watch mode)
/// speculation.recordChange(targetId);
/// 
/// // Record co-change relationships
/// speculation.recordCoChange(sourceTarget, affectedTarget);
/// ```
/// 
/// ## Components
/// 
/// ### ChangePredictor
/// Bayesian model that predicts probability of targets needing rebuild:
/// - Historical change frequency (EWMA smoothed)
/// - Recency decay (recent changes more predictive)
/// - Co-change correlations (if A changes, B often needs rebuild)
/// - Time-of-day patterns (adapt to developer schedules)
/// 
/// ### HistoryTracker
/// Persists and analyzes change patterns:
/// - Saves learned model between sessions
/// - Tracks prediction accuracy for feedback
/// - Identifies co-change relationships
/// 
/// ### SpeculativeEngine
/// Background execution engine:
/// - Dedicated worker threads for speculative builds
/// - Priority queue based on prediction confidence
/// - Input validation and abort semantics
/// 
/// ## Performance Impact
/// 
/// | Scenario | Impact |
/// |----------|--------|
/// | Large monorepo (1000+ targets) | 20-40% faster incremental builds |
/// | High prediction accuracy (>70%) | 30-50% faster critical path |
/// | Frequent small changes | Significant benefit from prediction |
/// | Cold start (no history) | Falls back to critical path only |
/// 
/// ## Configuration
/// 
/// Environment variables:
/// - `BUILDER_SPECULATION_ENABLED=0|1` - Enable/disable speculation
/// - `BUILDER_SPECULATION_POLICY=conservative|balanced|aggressive`
/// - `BUILDER_SPECULATION_WORKERS=N` - Number of background workers
/// 
/// ## See Also
/// - `engine.economics` - Cost estimation
/// - `engine.distributed.coordinator.profile` - Critical path analysis
/// - `engine.caching.incremental` - Dependency tracking

// Core service and policies
public import engine.runtime.services.speculation.service : 
    ISpeculationService,
    SpeculationService,
    SpeculationPolicy,
    SpeculativeTask,
    SpeculativeStatus,
    SpeculationStats,
    createSpeculationService;

// Executor for integration with build pipeline
public import engine.runtime.services.speculation.executor : 
    SpeculationExecutor,
    SpeculationExecutorStats,
    createSpeculationExecutor,
    createPredictiveSpeculationExecutor;

// Change probability prediction
public import engine.runtime.services.speculation.predictor :
    ChangePredictor,
    ChangeProbability,
    PredictorConfig,
    PredictorState,
    PredictorStats;

// History tracking and persistence
public import engine.runtime.services.speculation.history :
    HistoryTracker,
    HistoryConfig,
    HistoryStats,
    ChangeEvent,
    ChangeType,
    ChangeCorrelation,
    BuildSession;

// Speculative execution engine
public import engine.runtime.services.speculation.engine :
    SpeculativeEngine,
    SpeculativeResult,
    EngineConfig,
    EngineStats,
    createSpeculativeEngine;

// Cache-hit-based speculator (economics integration)
public import engine.runtime.services.speculation.speculator :
    SpeculativeExecutor,
    SpeculatorStats,
    SpeculationDecision,
    ConfirmCallback,
    AbortCallback,
    createSpeculator;
