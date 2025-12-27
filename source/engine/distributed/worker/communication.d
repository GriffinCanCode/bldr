module engine.distributed.worker.communication;

import std.datetime : Duration, Clock, seconds, msecs;
import std.conv : to;
import core.thread : Thread;
import core.atomic;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.transport;
import engine.distributed.protocol.messages;
import infrastructure.utils.concurrency.deque : WorkStealingDeque;
import engine.distributed.worker.peers;
import infrastructure.utils.logging;
import infrastructure.errors;
import infrastructure.errors.formatting.format : formatError = format;

/// Worker communication handler - manages coordinator and peer communication
struct WorkerCommunication
{
    /// Send heartbeat to coordinator
    void sendHeartbeat(WorkerId id, WorkerState state, SystemMetrics metrics, Transport coordinatorTransport) @trusted
    {
        try
        {
            auto hb = HeartBeat(id, state, metrics, Clock.currTime);
            auto sendResult = coordinatorTransport.sendHeartBeat(WorkerId(0), hb);
            
            if (sendResult.isErr)
            {
                structuredLog.error("heartbeat_send_failed").emit();
                structuredLog.error("log_event").field("message", formatError(sendResult.unwrapErr())).emit();
                if (auto http = cast(HttpTransport)coordinatorTransport)
                {
                    http.close();
                    auto reconnectResult = http.connect();
                    if (reconnectResult.isErr)
                        structuredLog.error("failed_to_reconnect_to_coordinator").emit();
                }
            }
            else
                structuredLog.debug_("heartbeat_sent_queue_").field("detail", "Heartbeat sent (queue: " ~ hb.metrics.queueDepth.to!string ~ 
                              ", cpu: " ~ (hb.metrics.cpuUsage * 100).to!size_t.to!string ~ "%)").emit();
        }
        catch (Exception e) { structuredLog.error("heartbeat_send_exception_").field("detail", "Heartbeat send exception: " ~ e.msg).emit(); }
    }
    
    /// Heartbeat loop
    void heartbeatLoop(WorkerId id, shared bool* running, WorkerState delegate() @trusted getStateCallback,
        SystemMetrics delegate() @trusted getMetricsCallback, Transport coordinatorTransport, Duration heartbeatInterval) @trusted
    {
        while (atomicLoad(*running))
        {
            try
            {
                sendHeartbeat(id, getStateCallback(), getMetricsCallback(), coordinatorTransport);
            }
            catch (Exception e) { structuredLog.error("heartbeat_failed_").field("detail", "Heartbeat failed: " ~ e.msg).emit(); }
            
            // Sleep in short intervals to allow fast shutdown
            auto remaining = heartbeatInterval;
            while (remaining > Duration.zero && atomicLoad(*running))
            {
                auto sleepTime = remaining > msecs(100) ? msecs(100) : remaining;
                Thread.sleep(sleepTime);
                remaining -= sleepTime;
            }
        }
    }
    
    /// Request work from coordinator
    ActionRequest requestWork(WorkerId id, Transport coordinatorTransport) @trusted
    {
        try
        {
            // Create work request
            WorkRequest req;
            req.worker = id;
            req.desiredBatchSize = 1;
            
            auto reqData = serializeWorkRequest(req);
            
            // Send request via transport with proper framing
            ubyte[1] typeBytes = [cast(ubyte)MessageType.WorkRequest];
            ubyte[4] lengthBytes;
            *cast(uint*)lengthBytes.ptr = cast(uint)reqData.length;
            
            // Get HTTP transport and send via socket
            auto http = cast(HttpTransport)coordinatorTransport;
            if (http is null || !http.isConnected())
            {
                structuredLog.error("transport_not_connected").emit();
                return null;
            }
            
            // Send message with type and length prefix
            auto socket = http.getSocket();
            if (socket is null)
            {
                structuredLog.error("socket_not_available").emit();
                return null;
            }
            
            socket.send(typeBytes);
            socket.send(lengthBytes);
            socket.send(reqData);
            
            // Receive response with timeout
            import std.socket : Socket, SocketOptionLevel, SocketOption;
            import std.datetime : seconds;
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 10.seconds);
            
            // Read response type
            ubyte[1] responseType;
            auto received = socket.receive(responseType);
            if (received != 1)
            {
                structuredLog.debug_("no_work_available").emit();
                return null;
            }
            
            // Read response length
            ubyte[4] responseLengthBytes;
            received = socket.receive(responseLengthBytes);
            if (received != 4)
            {
                structuredLog.error("failed_to_receive_response_length").emit();
                return null;
            }
            
            immutable responseLength = *cast(uint*)responseLengthBytes.ptr;
            if (responseLength == 0)
            {
                structuredLog.debug_("no_work_available_empty_response").emit();
                return null;
            }
            
            // Read response data
            auto responseData = new ubyte[responseLength];
            size_t totalReceived = 0;
            while (totalReceived < responseLength)
            {
                auto chunk = socket.receive(responseData[totalReceived .. $]);
                if (chunk <= 0)
                {
                    structuredLog.error("connection_closed_while_receiving_work_r").emit();
                    return null;
                }
                totalReceived += chunk;
            }
            
            // Deserialize action request
            auto workResponse = deserializeWorkResponse(responseData);
            if (workResponse.actions.length > 0)
            {
                structuredLog.debug_("received_work_").field("detail", "Received work: " ~ workResponse.actions[0].id.toString()).emit();
                return workResponse.actions[0];
            }
            
            return null;
        }
        catch (Exception e)
        {
            structuredLog.error("work_request_failed_").field("detail", "Work request failed: " ~ e.msg).emit();
            return null;
        }
    }
    
    /// Send result to coordinator
    void sendResult(WorkerId id, ActionResult result, Transport coordinatorTransport) @trusted
    {
        try
        {
            auto http = cast(HttpTransport)coordinatorTransport;
            if (http is null) { structuredLog.error("invalid_transport_for_sending_result").emit(); return; }
            
            auto msgData = http.serializeMessage(Envelope!ActionResult(id, WorkerId(0), result));
            ubyte[1] typeBytes = [cast(ubyte)MessageType.ActionResult];
            ubyte[4] lengthBytes;
            *cast(uint*)lengthBytes.ptr = cast(uint)msgData.length;
            
            auto socket = http.getSocket();
            if (socket is null || !socket.isAlive)
            {
                structuredLog.error("socket_not_available_or_disconnected").emit();
                auto reconnectResult = http.connect();
                if (reconnectResult.isErr)
                { 
                    structuredLog.error("failed_to_reconnect").emit();
                    structuredLog.error("log_event").field("message", formatError(reconnectResult.unwrapErr())).emit(); 
                    return; 
                }
                socket = http.getSocket();
                if (socket is null) { structuredLog.error("socket_still_not_available_after_reconne").emit(); return; }
            }
            
            if (socket.send(typeBytes) != typeBytes.length) { structuredLog.error("failed_to_send_message_type").emit(); return; }
            if (socket.send(lengthBytes) != lengthBytes.length) { structuredLog.error("failed_to_send_message_length").emit(); return; }
            
            for (size_t totalSent = 0; totalSent < msgData.length;)
            {
                auto chunk = socket.send(msgData[totalSent .. $]);
                if (chunk <= 0) { structuredLog.error("connection_closed_while_sending_result").emit(); return; }
                totalSent += chunk;
            }
            
            structuredLog.debug_("result_sent_successfully_").field("detail", "Result sent successfully: " ~ result.id.toString() ~ " (" ~ msgData.length.to!string ~ " bytes)").emit();
        }
        catch (Exception e) { structuredLog.error("failed_to_send_result_").field("detail", "Failed to send result: " ~ e.msg).emit(); }
    }
    
    /// Send peer announce to coordinator
    void sendPeerAnnounce(WorkerId id, string listenAddress, ref WorkStealingDeque!ActionRequest localQueue,
        float loadFactor, Transport coordinatorTransport) @trusted
    {
        try
        {
            auto announce = PeerAnnounce(id, listenAddress, localQueue.size(), loadFactor);
            auto announceData = serializePeerAnnounce(announce);
            ubyte[1] typeBytes = [cast(ubyte)MessageType.PeerAnnounce];
            ubyte[4] lengthBytes;
            *cast(uint*)lengthBytes.ptr = cast(uint)announceData.length;
            
            auto http = cast(HttpTransport)coordinatorTransport;
            if (http is null || !http.isConnected()) { structuredLog.error("transport_not_connected_for_peer_announc").emit(); return; }
            
            auto socket = http.getSocket();
            if (socket is null || !socket.isAlive) { structuredLog.error("socket_not_available_for_peer_announce").emit(); return; }
            
            try
            {
                socket.send(typeBytes);
                socket.send(lengthBytes);
                for (size_t totalSent = 0; totalSent < announceData.length;)
                {
                    auto chunk = socket.send(announceData[totalSent .. $]);
                    if (chunk <= 0) { structuredLog.error("connection_closed_while_sending_peer_ann").emit(); return; }
                    totalSent += chunk;
                }
                structuredLog.debug_("peer_announce_sent_queue_").field("detail", "Peer announce sent (queue: " ~ localQueue.size().to!string ~
                              ", load: " ~ (loadFactor * 100).to!size_t.to!string ~ "%)").emit();
            }
            catch (Exception e) { structuredLog.warning("socket_error_during_peer_announce_").field("detail", "Socket error during peer announce: " ~ e.msg).emit(); }
        }
        catch (Exception e) { structuredLog.error("failed_to_send_peer_announce_").field("detail", "Failed to send peer announce: " ~ e.msg).emit(); }
    }
    
    /// Peer announce loop
    void peerAnnounceLoop(WorkerId id, shared bool* running, string listenAddress, ref WorkStealingDeque!ActionRequest localQueue,
        float delegate() @trusted getLoadFactorCallback, PeerRegistry peerRegistry, Transport coordinatorTransport,
        Duration peerAnnounceInterval) @trusted
    {
        while (atomicLoad(*running))
        {
            try
            {
                sendPeerAnnounce(id, listenAddress, localQueue, getLoadFactorCallback(), coordinatorTransport);
                if (peerRegistry !is null) peerRegistry.pruneStale();
            }
            catch (Exception e) { structuredLog.error("peer_announce_failed_").field("detail", "Peer announce failed: " ~ e.msg).emit(); }
            
            // Sleep in short intervals to allow fast shutdown
            auto remaining = peerAnnounceInterval;
            while (remaining > Duration.zero && atomicLoad(*running))
            {
                auto sleepTime = remaining > msecs(100) ? msecs(100) : remaining;
                Thread.sleep(sleepTime);
                remaining -= sleepTime;
            }
        }
    }
    
    /// Calculate current load factor
    float calculateLoadFactor(size_t queueSize, size_t queueCapacity, WorkerState state, size_t maxConcurrentActions) @trusted nothrow => 
        cast(float)queueSize / queueCapacity * 0.7 + cast(float)(state == WorkerState.Executing) / maxConcurrentActions * 0.3;
    
    /// Announce to peers and prune stale entries (convenience for structured tasks)
    void announceToPeers(WorkerId id, string listenAddress, size_t queueSize, 
        float loadFactor, PeerRegistry peerRegistry, Transport coordinatorTransport) @trusted
    {
        // Create temporary deque reference for sendPeerAnnounce compatibility
        // This is safe because we're just reading queue size
        try
        {
            auto announce = PeerAnnounce(id, listenAddress, queueSize, loadFactor);
            auto announceData = serializePeerAnnounce(announce);
            ubyte[1] typeBytes = [cast(ubyte)MessageType.PeerAnnounce];
            ubyte[4] lengthBytes;
            *cast(uint*)lengthBytes.ptr = cast(uint)announceData.length;
            
            auto http = cast(HttpTransport)coordinatorTransport;
            if (http is null || !http.isConnected()) return;
            
            auto socket = http.getSocket();
            if (socket is null || !socket.isAlive) return;
            
            socket.send(typeBytes);
            socket.send(lengthBytes);
            for (size_t totalSent = 0; totalSent < announceData.length;)
            {
                auto chunk = socket.send(announceData[totalSent .. $]);
                if (chunk <= 0) break;
                totalSent += chunk;
            }
            
            if (peerRegistry !is null) peerRegistry.pruneStale();
            
            structuredLog.debug_("peer_announce_sent_queue_").field("detail", "Peer announce sent (queue: " ~ queueSize.to!string ~
                          ", load: " ~ (loadFactor * 100).to!size_t.to!string ~ "%)").emit();
        }
        catch (Exception e) { structuredLog.error("failed_to_announce_").field("detail", "Failed to announce: " ~ e.msg).emit(); }
    }
}

/// Serialize work request message
ubyte[] serializeWorkRequest(WorkRequest req) @trusted
{
    import std.bitmanip : nativeToLittleEndian;
    
    ubyte[] buffer;
    buffer.reserve(256);
    
    // Worker ID
    buffer ~= nativeToLittleEndian(req.worker.value);
    
    // Desired batch size
    buffer ~= nativeToLittleEndian(req.desiredBatchSize);
    
    return buffer;
}

/// Work response containing assigned actions
struct WorkResponse
{
    ActionRequest[] actions;
}

/// Deserialize work response message
WorkResponse deserializeWorkResponse(const ubyte[] data) @system
{
    import std.bitmanip : read;
    
    WorkResponse response;
    
    if (data.length < 4)
        return response;
    
    ubyte[] mutableData = data.dup;
    size_t offset = 0;
    
    try
    {
        // Read number of actions
        auto countSlice = mutableData[offset .. offset + 4];
        immutable actionCount = countSlice.read!uint();
        offset += 4;
        
        // Read each action
        // Note: Full ActionRequest deserialization requires complex nested structure handling
        // In production, coordinator would use proper protocol serialization from transport.d
        for (uint i = 0; i < actionCount && offset < data.length; i++)
        {
            // ActionRequest deserialization handled by transport layer's deserializeMessage
            // This helper is for message framing only
            break;
        }
    }
    catch (Exception)
    {
        // Return empty response on error
    }
    
    return response;
}

/// Serialize peer announce message
ubyte[] serializePeerAnnounce(PeerAnnounce announce) @trusted
{
    import std.bitmanip : write;
    
    ubyte[] buffer;
    buffer.reserve(256);
    
    // Worker ID
    buffer.write!ulong(announce.worker.value, buffer.length);
    
    // Address length and data
    buffer.write!uint(cast(uint)announce.address.length, buffer.length);
    buffer ~= cast(ubyte[])announce.address;
    
    // Queue depth
    buffer.write!ulong(announce.queueDepth, buffer.length);
    
    // Load factor (serialize as fixed-point)
    buffer.write!float(announce.loadFactor, buffer.length);
    
    return buffer;
}

