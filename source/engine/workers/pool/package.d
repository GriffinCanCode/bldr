module engine.workers.pool;

/// Worker Pool Management
/// 
/// SOC Design:
/// - manager.d: Coordination of workers, factories, lifecycle
/// - recycler.d: Warmth tracking, recycling policy decisions
/// - memory.d: Memory metrics collection, OOM detection
/// - persistent.d: High-level API with per-language locking for JVM/Go/Python

public import engine.workers.pool.manager;
public import engine.workers.pool.recycler;
public import engine.workers.pool.memory;
public import engine.workers.pool.persistent;

