module engine.runtime.services.scheduling;

/// Scheduling Service Module
/// Provides work-stealing and thread-pool scheduling capabilities

public import engine.runtime.services.scheduling.service : 
    ISchedulingService, 
    SchedulingService,
    SchedulingMode,
    SchedulingStats,
    NodeBuildResult;

