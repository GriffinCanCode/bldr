module engine.distributed.protocol.grpc.types;

import std.datetime : Duration;
import engine.distributed.protocol.protocol;

/// Execution progress for streaming
struct ExecutionProgress {
    ActionId actionId;
    
    enum Stage {
        Queued,
        InputFetch,
        Executing,
        OutputUpload,
        Complete
    }
    Stage stage;
    
    float progress;      // 0.0 - 1.0
    string message;
}

/// Response from worker registration
struct RegisterWorkerResponse {
    bool accepted;
    string message;
    WorkerId[] peers;
    Duration heartbeatInterval;
}

/// Command from coordinator
struct CoordinatorCommand {
    enum Type {
        Shutdown,
        PushWork
    }
    Type type;
    
    // Payload depends on type
    Shutdown shutdown;
    ActionRequest action;
}

