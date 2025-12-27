module engine.distributed.coordinator.messages;

import std.socket : Socket, SocketShutdown;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.messages;
import engine.distributed.protocol.transport : HttpTransport;
import engine.distributed.coordinator.registry : WorkerRegistry;
import engine.distributed.coordinator.scheduler : DistributedScheduler;
import infrastructure.errors;
import infrastructure.errors.formatting.format : formatError = format;
import infrastructure.utils.logging;

/// Coordinator message handler - single responsibility: handle incoming messages
/// 
/// Separation of concerns:
/// - Coordinator: orchestrates distributed execution, manages lifecycle
/// - CoordinatorMessageHandler: handles message routing and deserialization
/// - WorkerRegistry: manages worker state
/// - DistributedScheduler: manages action scheduling
final class CoordinatorMessageHandler
{
    private WorkerRegistry registry;
    private DistributedScheduler scheduler;
    
    this(WorkerRegistry registry, DistributedScheduler scheduler) @safe
    {
        this.registry = registry;
        this.scheduler = scheduler;
    }
    
    /// Handle incoming client connection (Responsibility: Route message to appropriate handler based on type)
    void handleClient(Socket client) @trusted
    {
        scope(exit) cleanupSocket(client);
        
        try
        {
            ubyte[1] typeBytes;
            if (client.receive(typeBytes) != 1) return;
            
            final switch (cast(MessageType)typeBytes[0])
            {
                case MessageType.Registration: handleRegistration(client); break;
                case MessageType.HeartBeat: handleHeartBeat(client); break;
                case MessageType.ActionResult: handleActionResult(client); break;
                case MessageType.WorkRequest: handleWorkRequest(client); break;
                case MessageType.PeerDiscovery, MessageType.PeerAnnounce, MessageType.PeerMetrics:
                    structuredLog.info("peer_message_received").emit(); break;
                case MessageType.ActionRequest, MessageType.StealRequest, MessageType.StealResponse, MessageType.Shutdown:
                    structuredLog.warning("unexpected_message_type_from_client").emit(); break;
            }
        }
        catch (Exception e) { structuredLog.error("client_handler_failed_").field("detail", "Client handler failed: " ~ e.msg).emit(); }
    }
    
    /// Handle worker registration message (Responsibility: Parse registration and delegate to registry)
    private void handleRegistration(Socket client) @trusted
    {
        try
        {
            ubyte[4] lengthBytes;
            if (client.receive(lengthBytes) != 4) return;
            
            immutable length = *cast(uint*)lengthBytes.ptr;
            auto data = new ubyte[length];
            if (client.receive(data) != length) return;
            
            auto regResult = deserializeRegistration(data);
            if (regResult.isErr) { 
                structuredLog.error("failed_to_deserialize_registration").emit();
                structuredLog.error("log_event").field("message", formatError(regResult.unwrapErr())).emit(); 
                return; 
            }
            
            auto registration = regResult.unwrap();
            auto workerIdResult = registry.register(registration.address);
            if (workerIdResult.isErr) { 
                structuredLog.error("failed_to_register_worker").emit();
                structuredLog.error("log_event").field("message", formatError(workerIdResult.unwrapErr())).emit(); 
                return; 
            }
            
            auto workerId = workerIdResult.unwrap();
            ubyte[8] idBytes;
            *cast(ulong*)idBytes.ptr = workerId.value;
            client.send(idBytes);
            
            structuredLog.info("worker_registered_").field("detail", "Worker registered: " ~ workerId.toString() ~ " (" ~ registration.address ~ ")").emit();
        }
        catch (Exception e) { structuredLog.error("registration_handling_failed_").field("detail", "Registration handling failed: " ~ e.msg).emit(); }
    }
    
    /// Handle heartbeat message (Responsibility: Parse heartbeat and delegate to registry)
    private void handleHeartBeat(Socket client) @trusted
    {
        try
        {
            ubyte[4] lengthBytes;
            if (client.receive(lengthBytes) != 4) return;
            
            immutable length = *cast(uint*)lengthBytes.ptr;
            auto data = new ubyte[length];
            if (client.receive(data) != length) return;
            
            auto http = new HttpTransport("", 0);
            auto envResult = http.deserializeMessage!HeartBeat(data);
            if (envResult.isErr) return;
            
            auto envelope = envResult.unwrap();
            registry.updateHeartbeat(envelope.payload.worker, envelope.payload);
            structuredLog.debug_("heartbeat_from_worker_").field("detail", "Heartbeat from worker " ~ envelope.payload.worker.toString()).emit();
        }
        catch (Exception e) { structuredLog.error("heartbeat_handling_failed_").field("detail", "Heartbeat handling failed: " ~ e.msg).emit(); }
    }
    
    /// Handle action result message (Responsibility: Parse action result and delegate to scheduler)
    private void handleActionResult(Socket client) @trusted
    {
        try
        {
            ubyte[4] lengthBytes;
            if (client.receive(lengthBytes) != 4) return;
            
            immutable length = *cast(uint*)lengthBytes.ptr;
            auto data = new ubyte[length];
            if (client.receive(data) != length) return;
            
            auto http = new HttpTransport("", 0);
            auto envResult = http.deserializeMessage!ActionResult(data);
            if (envResult.isErr) { structuredLog.error("failed_to_deserialize_result").emit(); return; }
            
            auto result = envResult.unwrap().payload;
            if (result.status == ResultStatus.Success) scheduler.onComplete(result.id, result);
            else scheduler.onFailure(result.id, result.stderr);
            
            structuredLog.info("action_completed_").field("detail", "Action completed: " ~ result.id.toString()).emit();
        }
        catch (Exception e) { structuredLog.error("result_handling_failed_").field("detail", "Result handling failed: " ~ e.msg).emit(); }
    }
    
    /// Handle work request message (Responsibility: Parse work request and delegate to scheduler)
    void handleWorkRequest(Socket client) @trusted
    {
        try
        {
            ubyte[4] lengthBytes;
            if (client.receive(lengthBytes) != 4) return;
            
            immutable length = *cast(uint*)lengthBytes.ptr;
            auto data = new ubyte[length];
            if (client.receive(data) != length) return;
            
            auto reqResult = deserializeWorkRequest(data);
            if (reqResult.isErr) return;
            
            auto request = reqResult.unwrap();
            ActionRequest[] actions;
            foreach (_; 0 .. request.desiredBatchSize)
            {
                auto actionResult = scheduler.dequeueReady();
                if (actionResult.isErr) break;
                actions ~= actionResult.unwrap();
            }
            
            ubyte[4] countBytes;
            *cast(uint*)countBytes.ptr = cast(uint)actions.length;
            client.send(countBytes);
            
            if (actions.length > 0)
            {
                foreach (action; actions)
                {
                    scheduler.assign(action.id, request.worker);
                    auto serialized = action.serialize();
                    ubyte[4] lenBytes;
                    *cast(uint*)lenBytes.ptr = cast(uint)serialized.length;
                    client.send(lenBytes);
                    client.send(serialized);
                }
                import std.conv : to;
                structuredLog.debug_("sent_").field("detail", "Sent " ~ actions.length.to!string ~ " actions to worker " ~ request.worker.toString()).emit();
            }
        }
        catch (Exception e) { structuredLog.error("work_request_handling_failed_").field("detail", "Work request handling failed: " ~ e.msg).emit(); }
    }
    
    private void cleanupSocket(Socket client) nothrow
    {
        try { client.shutdown(SocketShutdown.BOTH); client.close(); } 
        catch (Exception) {}
    }
}

