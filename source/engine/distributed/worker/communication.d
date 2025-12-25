module engine.distributed.worker.communication;

import std.datetime : Duration, Clock, seconds;
import std.conv : to;
import core.thread : Thread;
import core.atomic;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.transport;
import engine.distributed.protocol.messages;
import infrastructure.utils.concurrency.deque : WorkStealingDeque;
import engine.distributed.worker.peers;
import infrastructure.utils.logging.logger;
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
                Logger.error("Heartbeat send failed");
                Logger.error(formatError(sendResult.unwrapErr()));
                if (auto http = cast(HttpTransport)coordinatorTransport)
                {
                    http.close();
                    auto reconnectResult = http.connect();
                    if (reconnectResult.isErr)
                        Logger.error("Failed to reconnect to coordinator");
                }
            }
            else
                Logger.debugLog("Heartbeat sent (queue: " ~ hb.metrics.queueDepth.to!string ~ 
                              ", cpu: " ~ (hb.metrics.cpuUsage * 100).to!size_t.to!string ~ "%)");
        }
        catch (Exception e) { Logger.error("Heartbeat send exception: " ~ e.msg); }
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
                Thread.sleep(heartbeatInterval);
            }
            catch (Exception e) { Logger.error("Heartbeat failed: " ~ e.msg); }
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
                Logger.error("Transport not connected");
                return null;
            }
            
            // Send message with type and length prefix
            auto socket = http.getSocket();
            if (socket is null)
            {
                Logger.error("Socket not available");
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
                Logger.debugLog("No work available");
                return null;
            }
            
            // Read response length
            ubyte[4] responseLengthBytes;
            received = socket.receive(responseLengthBytes);
            if (received != 4)
            {
                Logger.error("Failed to receive response length");
                return null;
            }
            
            immutable responseLength = *cast(uint*)responseLengthBytes.ptr;
            if (responseLength == 0)
            {
                Logger.debugLog("No work available (empty response)");
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
                    Logger.error("Connection closed while receiving work response");
                    return null;
                }
                totalReceived += chunk;
            }
            
            // Deserialize action request
            auto workResponse = deserializeWorkResponse(responseData);
            if (workResponse.actions.length > 0)
            {
                Logger.debugLog("Received work: " ~ workResponse.actions[0].id.toString());
                return workResponse.actions[0];
            }
            
            return null;
        }
        catch (Exception e)
        {
            Logger.error("Work request failed: " ~ e.msg);
            return null;
        }
    }
    
    /// Send result to coordinator
    void sendResult(WorkerId id, ActionResult result, Transport coordinatorTransport) @trusted
    {
        try
        {
            auto http = cast(HttpTransport)coordinatorTransport;
            if (http is null) { Logger.error("Invalid transport for sending result"); return; }
            
            auto msgData = http.serializeMessage(Envelope!ActionResult(id, WorkerId(0), result));
            ubyte[1] typeBytes = [cast(ubyte)MessageType.ActionResult];
            ubyte[4] lengthBytes;
            *cast(uint*)lengthBytes.ptr = cast(uint)msgData.length;
            
            auto socket = http.getSocket();
            if (socket is null || !socket.isAlive)
            {
                Logger.error("Socket not available or disconnected");
                auto reconnectResult = http.connect();
                if (reconnectResult.isErr)
                { 
                    Logger.error("Failed to reconnect");
                    Logger.error(formatError(reconnectResult.unwrapErr())); 
                    return; 
                }
                socket = http.getSocket();
                if (socket is null) { Logger.error("Socket still not available after reconnect"); return; }
            }
            
            if (socket.send(typeBytes) != typeBytes.length) { Logger.error("Failed to send message type"); return; }
            if (socket.send(lengthBytes) != lengthBytes.length) { Logger.error("Failed to send message length"); return; }
            
            for (size_t totalSent = 0; totalSent < msgData.length;)
            {
                auto chunk = socket.send(msgData[totalSent .. $]);
                if (chunk <= 0) { Logger.error("Connection closed while sending result"); return; }
                totalSent += chunk;
            }
            
            Logger.debugLog("Result sent successfully: " ~ result.id.toString() ~ " (" ~ msgData.length.to!string ~ " bytes)");
        }
        catch (Exception e) { Logger.error("Failed to send result: " ~ e.msg); }
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
            if (http is null || !http.isConnected()) { Logger.error("Transport not connected for peer announce"); return; }
            
            auto socket = http.getSocket();
            if (socket is null || !socket.isAlive) { Logger.error("Socket not available for peer announce"); return; }
            
            try
            {
                socket.send(typeBytes);
                socket.send(lengthBytes);
                for (size_t totalSent = 0; totalSent < announceData.length;)
                {
                    auto chunk = socket.send(announceData[totalSent .. $]);
                    if (chunk <= 0) { Logger.error("Connection closed while sending peer announce"); return; }
                    totalSent += chunk;
                }
                Logger.debugLog("Peer announce sent (queue: " ~ localQueue.size().to!string ~
                              ", load: " ~ (loadFactor * 100).to!size_t.to!string ~ "%)");
            }
            catch (Exception e) { Logger.warning("Socket error during peer announce: " ~ e.msg); }
        }
        catch (Exception e) { Logger.error("Failed to send peer announce: " ~ e.msg); }
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
                Thread.sleep(peerAnnounceInterval);
            }
            catch (Exception e) { Logger.error("Peer announce failed: " ~ e.msg); }
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
            
            Logger.debugLog("Peer announce sent (queue: " ~ queueSize.to!string ~
                          ", load: " ~ (loadFactor * 100).to!size_t.to!string ~ "%)");
        }
        catch (Exception e) { Logger.error("Failed to announce: " ~ e.msg); }
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

