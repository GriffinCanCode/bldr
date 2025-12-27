module infrastructure.errors.codes.distributed;

import infrastructure.errors.codes.category : ErrorCategory;
import infrastructure.errors.codes.recoverability : Recoverability;

/// Distributed build error codes (12000-12999)
/// Covers remote execution, workers, and coordination
enum Distributed : int
{
    /// Generic distributed error
    Error = 12000,
    /// Coordinator not found
    CoordinatorNotFound = 12001,
    /// Coordinator connection timeout
    CoordinatorTimeout = 12002,
    /// Worker timeout
    WorkerTimeout = 12003,
    /// Worker failed
    WorkerFailed = 12004,
    /// Failed to schedule action
    ActionSchedulingFailed = 12005,
    /// Sandbox execution error
    SandboxError = 12006,
    /// Artifact transfer failed
    ArtifactTransferFailed = 12007,
    /// No workers available
    NoWorkersAvailable = 12008,
    /// Worker capacity exceeded
    WorkerCapacityExceeded = 12009,
    /// Action rejected
    ActionRejected = 12010,
    /// Platform mismatch
    PlatformMismatch = 12011,
    /// Remote execution disabled
    RemoteDisabled = 12012,
    /// Invalid action
    InvalidAction = 12013,
    /// Action too large
    ActionTooLarge = 12014,
    /// Output directory missing
    OutputDirectoryMissing = 12015,
    /// Input missing on remote
    InputMissing = 12016,
    /// Execution policy violated
    PolicyViolation = 12017,
    /// Remote cache sync failed
    CacheSyncFailed = 12018,
    /// Scheduler overloaded
    SchedulerOverloaded = 12019,
    /// Worker registration failed
    WorkerRegistrationFailed = 12020,
    /// Heartbeat failed
    HeartbeatFailed = 12021,
    /// Lease expired
    LeaseExpired = 12022,
    /// Action already executing
    ActionAlreadyExecuting = 12023,
    /// Coordination lock failed
    LockFailed = 12024,
}

/// Namespace for distributed error utilities
struct DistributedErrors
{
    static ErrorCategory category() pure nothrow @nogc { return ErrorCategory.Distributed; }
    
    static Recoverability recoverabilityOf(Distributed code) pure nothrow @nogc
    {
        switch (code)
        {
            case Distributed.CoordinatorTimeout:
            case Distributed.WorkerTimeout:
            case Distributed.WorkerFailed:
            case Distributed.ArtifactTransferFailed:
            case Distributed.NoWorkersAvailable:
            case Distributed.WorkerCapacityExceeded:
            case Distributed.CacheSyncFailed:
            case Distributed.SchedulerOverloaded:
            case Distributed.HeartbeatFailed:
            case Distributed.LeaseExpired:
            case Distributed.LockFailed:
                return Recoverability.Transient;
            case Distributed.CoordinatorNotFound:
            case Distributed.PlatformMismatch:
            case Distributed.RemoteDisabled:
            case Distributed.InvalidAction:
            case Distributed.ActionTooLarge:
            case Distributed.PolicyViolation:
                return Recoverability.User;
            default:
                return Recoverability.Fatal;
        }
    }
    
    static string messageOf(Distributed code) pure nothrow @safe
    {
        final switch (code)
        {
            case Distributed.Error:                    return "Distributed build error";
            case Distributed.CoordinatorNotFound:      return "Build coordinator not found";
            case Distributed.CoordinatorTimeout:       return "Coordinator connection timeout";
            case Distributed.WorkerTimeout:            return "Worker timeout";
            case Distributed.WorkerFailed:             return "Worker failure";
            case Distributed.ActionSchedulingFailed:   return "Failed to schedule action";
            case Distributed.SandboxError:             return "Sandbox execution error";
            case Distributed.ArtifactTransferFailed:   return "Artifact transfer failed";
            case Distributed.NoWorkersAvailable:       return "No workers available";
            case Distributed.WorkerCapacityExceeded:   return "Worker capacity exceeded";
            case Distributed.ActionRejected:           return "Action rejected";
            case Distributed.PlatformMismatch:         return "Platform mismatch";
            case Distributed.RemoteDisabled:           return "Remote execution disabled";
            case Distributed.InvalidAction:            return "Invalid action";
            case Distributed.ActionTooLarge:           return "Action too large";
            case Distributed.OutputDirectoryMissing:   return "Output directory missing";
            case Distributed.InputMissing:             return "Input missing on remote";
            case Distributed.PolicyViolation:          return "Execution policy violated";
            case Distributed.CacheSyncFailed:          return "Remote cache sync failed";
            case Distributed.SchedulerOverloaded:      return "Scheduler overloaded";
            case Distributed.WorkerRegistrationFailed: return "Worker registration failed";
            case Distributed.HeartbeatFailed:          return "Heartbeat failed";
            case Distributed.LeaseExpired:             return "Lease expired";
            case Distributed.ActionAlreadyExecuting:   return "Action already executing";
            case Distributed.LockFailed:               return "Coordination lock failed";
        }
    }
}

