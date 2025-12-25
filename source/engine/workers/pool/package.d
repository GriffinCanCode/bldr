module engine.workers.pool;

/// Worker Pool Management
/// 
/// SOC Design:
/// - manager.d: Coordination of workers, factories, lifecycle
/// - recycler.d: Warmth tracking, recycling policy decisions
/// - memory.d: Memory metrics collection, OOM detection

public import engine.workers.pool.manager;
public import engine.workers.pool.recycler;
public import engine.workers.pool.memory;

