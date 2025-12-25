module engine.runtime.services.speculation;

/// Speculative Execution for Critical Path Optimization
/// 
/// ## Overview
/// Speculatively executes likely-to-be-needed targets before their dependents
/// complete, using critical path analysis and cost estimation to make informed
/// speculation decisions. Aborts speculative work if inputs change.
/// 
/// ## Key Concepts
/// 
/// ### Critical Path Speculation
/// Identifies the longest weighted path through the build graph and speculatively
/// starts targets on that path before all dependencies complete, betting that:
/// 1. Cache hits will provide inputs faster than computation
/// 2. Input files won't change during speculation
/// 3. The cost savings from parallelism outweigh wasted speculation
/// 
/// ### Speculation Economics
/// Uses the economics module to make principled tradeoffs:
/// - Speculate on expensive targets (high cost/time savings)
/// - Avoid speculation on cheap targets (overhead > benefit)
/// - Budget-constrained speculation (max concurrent speculative tasks)
/// 
/// ### Abort Semantics
/// Speculative work is tracked with input hashes. If any input changes:
/// 1. In-progress speculation is marked for cancellation
/// 2. Results are discarded (not cached)
/// 3. Regular execution proceeds with updated inputs
/// 
/// ## Architecture
/// ```
/// ┌─────────────────────────────────────────────────────┐
/// │               SpeculationService                     │
/// │                                                      │
/// │  ┌──────────────────┐    ┌───────────────────────┐ │
/// │  │ CriticalPath     │    │ SpeculativeTask      │ │
/// │  │ Analyzer         │───▶│ - inputHashes        │ │
/// │  │ - profile        │    │ - status (atomic)    │ │
/// │  │ - economics      │    │ - cancellationToken  │ │
/// │  └──────────────────┘    └───────────────────────┘ │
/// │           │                        │                │
/// │           ▼                        ▼                │
/// │  ┌──────────────────┐    ┌───────────────────────┐ │
/// │  │ SpeculationPolicy│    │ AbortController      │ │
/// │  │ - maxConcurrent  │    │ - inputWatcher       │ │
/// │  │ - minCostMs      │    │ - hashValidator      │ │
/// │  │ - confidence     │    └───────────────────────┘ │
/// │  └──────────────────┘                              │
/// └─────────────────────────────────────────────────────┘
/// ```
/// 
/// ## Usage
/// ```d
/// auto speculation = services.createSpeculationService(graph, estimator);
/// speculation.setPolicy(SpeculationPolicy.aggressive());
/// 
/// // Start speculation during build
/// speculation.beginSpeculation();
/// 
/// // Abort on input change
/// speculation.notifyInputChanged(targetId, newHash);
/// 
/// // Get speculative results (if valid)
/// if (auto result = speculation.getSpeculativeResult(targetId))
///     useResult(result);
/// ```

public import engine.runtime.services.speculation.service;
public import engine.runtime.services.speculation.executor;

