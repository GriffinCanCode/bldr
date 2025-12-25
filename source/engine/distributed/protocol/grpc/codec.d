module engine.distributed.protocol.grpc.codec;

import std.datetime : Duration, SysTime, Clock;
import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.conv : to;
import engine.distributed.protocol.protocol;
import engine.distributed.protocol.grpc.types;
import infrastructure.errors;

/**
 * gRPC Codec for encoding/decoding Builder protocol messages
 * 
 * Uses protobuf-compatible wire format for interoperability with
 * standard gRPC implementations.
 */
final class GrpcCodec {
    /// Protobuf wire types
    enum WireType : ubyte {
        Varint = 0,
        Fixed64 = 1,
        LengthDelimited = 2,
        Fixed32 = 5
    }
    
    // =========================================================================
    // Builder Protocol Encoding
    // =========================================================================
    
    /// Encode HeartBeat message
    ubyte[] encodeHeartBeat(HeartBeat msg) @trusted {
        ubyte[] buf;
        buf.reserve(64);
        
        // Field 1: worker (WorkerId)
        buf ~= makeTag(1, WireType.LengthDelimited);
        auto workerBuf = encodeWorkerId(msg.worker);
        buf ~= encodeVarint(workerBuf.length);
        buf ~= workerBuf;
        
        // Field 2: state (enum)
        buf ~= makeTag(2, WireType.Varint);
        buf ~= encodeVarint(msg.state);
        
        // Field 3: metrics (SystemMetrics)
        buf ~= makeTag(3, WireType.LengthDelimited);
        auto metricsBuf = encodeSystemMetrics(msg.metrics);
        buf ~= encodeVarint(metricsBuf.length);
        buf ~= metricsBuf;
        
        // Field 4: timestamp
        buf ~= makeTag(4, WireType.Varint);
        buf ~= encodeVarint(msg.timestamp.stdTime / 10_000);  // Convert to millis
        
        return buf;
    }
    
    /// Encode StealRequest message
    ubyte[] encodeStealRequest(StealRequest msg) @trusted {
        ubyte[] buf;
        buf.reserve(32);
        
        // Field 1: thief
        buf ~= makeTag(1, WireType.LengthDelimited);
        auto thiefBuf = encodeWorkerId(msg.thief);
        buf ~= encodeVarint(thiefBuf.length);
        buf ~= thiefBuf;
        
        // Field 2: victim
        buf ~= makeTag(2, WireType.LengthDelimited);
        auto victimBuf = encodeWorkerId(msg.victim);
        buf ~= encodeVarint(victimBuf.length);
        buf ~= victimBuf;
        
        // Field 3: minPriority
        buf ~= makeTag(3, WireType.Varint);
        buf ~= encodeVarint(msg.minPriority);
        
        return buf;
    }
    
    /// Encode StealResponse message
    ubyte[] encodeStealResponse(StealResponse msg) @trusted {
        ubyte[] buf;
        buf.reserve(64);
        
        // Field 1: victim
        buf ~= makeTag(1, WireType.LengthDelimited);
        auto victimBuf = encodeWorkerId(msg.victim);
        buf ~= encodeVarint(victimBuf.length);
        buf ~= victimBuf;
        
        // Field 2: thief
        buf ~= makeTag(2, WireType.LengthDelimited);
        auto thiefBuf = encodeWorkerId(msg.thief);
        buf ~= encodeVarint(thiefBuf.length);
        buf ~= thiefBuf;
        
        // Field 3: hasWork
        buf ~= makeTag(3, WireType.Varint);
        buf ~= msg.hasWork ? 0x01 : 0x00;
        
        // Field 4: action (if hasWork)
        if (msg.hasWork && msg.action !is null) {
            buf ~= makeTag(4, WireType.LengthDelimited);
            auto actionBuf = encodeActionRequest(msg.action);
            buf ~= encodeVarint(actionBuf.length);
            buf ~= actionBuf;
        }
        
        return buf;
    }
    
    /// Encode ActionRequest message
    ubyte[] encodeActionRequest(ActionRequest req) @trusted {
        if (req is null) return [];
        
        ubyte[] buf;
        buf.reserve(512);
        
        // Field 1: id (ActionId - 32 bytes)
        buf ~= makeTag(1, WireType.LengthDelimited);
        buf ~= encodeVarint(32);
        buf ~= req.id.hash[];
        
        // Field 2: command
        if (req.command.length > 0) {
            buf ~= makeTag(2, WireType.LengthDelimited);
            buf ~= encodeVarint(req.command.length);
            buf ~= cast(ubyte[])req.command;
        }
        
        // Field 3: env (map)
        foreach (k, v; req.env) {
            buf ~= makeTag(3, WireType.LengthDelimited);
            auto envBuf = encodeEnvEntry(k, v);
            buf ~= encodeVarint(envBuf.length);
            buf ~= envBuf;
        }
        
        // Field 4: inputs
        foreach (input; req.inputs) {
            buf ~= makeTag(4, WireType.LengthDelimited);
            auto inputBuf = encodeInputSpec(input);
            buf ~= encodeVarint(inputBuf.length);
            buf ~= inputBuf;
        }
        
        // Field 5: outputs
        foreach (output; req.outputs) {
            buf ~= makeTag(5, WireType.LengthDelimited);
            auto outputBuf = encodeOutputSpec(output);
            buf ~= encodeVarint(outputBuf.length);
            buf ~= outputBuf;
        }
        
        // Field 6: capabilities
        buf ~= makeTag(6, WireType.LengthDelimited);
        auto capsBuf = encodeCapabilities(req.capabilities);
        buf ~= encodeVarint(capsBuf.length);
        buf ~= capsBuf;
        
        // Field 7: priority
        buf ~= makeTag(7, WireType.Varint);
        buf ~= encodeVarint(req.priority);
        
        // Field 8: timeout_ms
        buf ~= makeTag(8, WireType.Varint);
        buf ~= encodeVarint(req.timeout.total!"msecs");
        
        return buf;
    }
    
    /// Encode RegisterWorkerRequest
    ubyte[] encodeRegisterWorkerRequest(
        WorkerId workerId, 
        string address, 
        Capabilities caps, 
        uint maxConcurrent
    ) @trusted {
        ubyte[] buf;
        buf.reserve(128);
        
        // Field 1: worker_id
        buf ~= makeTag(1, WireType.LengthDelimited);
        auto workerBuf = encodeWorkerId(workerId);
        buf ~= encodeVarint(workerBuf.length);
        buf ~= workerBuf;
        
        // Field 2: address
        buf ~= makeTag(2, WireType.LengthDelimited);
        buf ~= encodeVarint(address.length);
        buf ~= cast(ubyte[])address;
        
        // Field 3: capabilities
        buf ~= makeTag(3, WireType.LengthDelimited);
        auto capsBuf = encodeCapabilities(caps);
        buf ~= encodeVarint(capsBuf.length);
        buf ~= capsBuf;
        
        // Field 4: max_concurrent
        buf ~= makeTag(4, WireType.Varint);
        buf ~= encodeVarint(maxConcurrent);
        
        return buf;
    }
    
    // =========================================================================
    // Builder Protocol Decoding
    // =========================================================================
    
    /// Decode ActionResult from bytes
    Result!(ActionResult, DistributedError) decodeActionResult(const(ubyte)[] data) @trusted {
        ActionResult result;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto tagResult = decodeTag(data[offset .. $]);
            if (tagResult.isErr) break;
            
            auto tag = tagResult.unwrap();
            offset += tag.bytesRead;
            
            switch (tag.fieldNumber) {
                case 1:  // id
                    auto lenResult = decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) break;
                    offset += lenResult.unwrap().bytesRead;
                    auto len = cast(size_t)lenResult.unwrap().value;
                    if (len == 32)
                        result.id = ActionId(data[offset .. offset + 32]);
                    offset += len;
                    break;
                    
                case 2:  // status
                    auto valResult = decodeVarint(data[offset .. $]);
                    if (valResult.isErr) break;
                    offset += valResult.unwrap().bytesRead;
                    result.status = cast(ResultStatus)valResult.unwrap().value;
                    break;
                    
                case 3:  // duration_ms
                    auto valResult = decodeVarint(data[offset .. $]);
                    if (valResult.isErr) break;
                    offset += valResult.unwrap().bytesRead;
                    import std.datetime : msecs;
                    result.duration = valResult.unwrap().value.msecs;
                    break;
                    
                case 5:  // stdout
                    auto lenResult = decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) break;
                    offset += lenResult.unwrap().bytesRead;
                    auto len = cast(size_t)lenResult.unwrap().value;
                    result.stdout = cast(string)data[offset .. offset + len];
                    offset += len;
                    break;
                    
                case 6:  // stderr
                    auto lenResult = decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) break;
                    offset += lenResult.unwrap().bytesRead;
                    auto len = cast(size_t)lenResult.unwrap().value;
                    result.stderr = cast(string)data[offset .. offset + len];
                    offset += len;
                    break;
                    
                case 7:  // exit_code
                    auto valResult = decodeVarint(data[offset .. $]);
                    if (valResult.isErr) break;
                    offset += valResult.unwrap().bytesRead;
                    result.exitCode = cast(int)valResult.unwrap().value;
                    break;
                    
                default:
                    auto skipResult = skipField(data[offset .. $], tag.wireType);
                    if (skipResult.isErr) break;
                    offset += skipResult.unwrap();
                    break;
            }
        }
        
        return Ok!(ActionResult, DistributedError)(result);
    }
    
    /// Decode ExecutionProgress from bytes
    Result!(ExecutionProgress, DistributedError) decodeExecutionProgress(const(ubyte)[] data) @trusted {
        ExecutionProgress progress;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto tagResult = decodeTag(data[offset .. $]);
            if (tagResult.isErr) break;
            
            auto tag = tagResult.unwrap();
            offset += tag.bytesRead;
            
            switch (tag.fieldNumber) {
                case 2:  // stage
                    auto valResult = decodeVarint(data[offset .. $]);
                    if (valResult.isErr) break;
                    offset += valResult.unwrap().bytesRead;
                    progress.stage = cast(ExecutionProgress.Stage)valResult.unwrap().value;
                    break;
                    
                case 3:  // progress
                    if (tag.wireType == WireType.Fixed32) {
                        if (data.length >= offset + 4) {
                            ubyte[4] floatBytes = data[offset .. offset + 4][0 .. 4];
                            progress.progress = *cast(float*)floatBytes.ptr;
                            offset += 4;
                        }
                    }
                    break;
                    
                case 4:  // message
                    auto lenResult = decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) break;
                    offset += lenResult.unwrap().bytesRead;
                    auto len = cast(size_t)lenResult.unwrap().value;
                    progress.message = cast(string)data[offset .. offset + len];
                    offset += len;
                    break;
                    
                default:
                    auto skipResult = skipField(data[offset .. $], tag.wireType);
                    if (skipResult.isErr) break;
                    offset += skipResult.unwrap();
                    break;
            }
        }
        
        return Ok!(ExecutionProgress, DistributedError)(progress);
    }
    
    /// Decode RegisterWorkerResponse
    Result!(RegisterWorkerResponse, DistributedError) decodeRegisterWorkerResponse(
        const(ubyte)[] data
    ) @trusted {
        RegisterWorkerResponse resp;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto tagResult = decodeTag(data[offset .. $]);
            if (tagResult.isErr) break;
            
            auto tag = tagResult.unwrap();
            offset += tag.bytesRead;
            
            switch (tag.fieldNumber) {
                case 1:  // accepted
                    auto valResult = decodeVarint(data[offset .. $]);
                    if (valResult.isErr) break;
                    offset += valResult.unwrap().bytesRead;
                    resp.accepted = valResult.unwrap().value != 0;
                    break;
                    
                case 2:  // message
                    auto lenResult = decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) break;
                    offset += lenResult.unwrap().bytesRead;
                    auto len = cast(size_t)lenResult.unwrap().value;
                    resp.message = cast(string)data[offset .. offset + len];
                    offset += len;
                    break;
                    
                default:
                    auto skipResult = skipField(data[offset .. $], tag.wireType);
                    if (skipResult.isErr) break;
                    offset += skipResult.unwrap();
                    break;
            }
        }
        
        return Ok!(RegisterWorkerResponse, DistributedError)(resp);
    }
    
    // =========================================================================
    // Helper Encoding Methods
    // =========================================================================
    
    private ubyte[] encodeWorkerId(WorkerId id) @trusted {
        ubyte[] buf;
        buf ~= makeTag(1, WireType.Varint);
        buf ~= encodeVarint(id.value);
        return buf;
    }
    
    private ubyte[] encodeSystemMetrics(SystemMetrics m) @trusted {
        ubyte[] buf;
        
        // cpu_usage (float as fixed32)
        buf ~= makeTag(1, WireType.Fixed32);
        buf ~= (cast(ubyte*)&m.cpuUsage)[0 .. 4];
        
        // memory_usage
        buf ~= makeTag(2, WireType.Fixed32);
        buf ~= (cast(ubyte*)&m.memoryUsage)[0 .. 4];
        
        // disk_usage
        buf ~= makeTag(3, WireType.Fixed32);
        buf ~= (cast(ubyte*)&m.diskUsage)[0 .. 4];
        
        // queue_depth
        buf ~= makeTag(4, WireType.Varint);
        buf ~= encodeVarint(m.queueDepth);
        
        // active_actions
        buf ~= makeTag(5, WireType.Varint);
        buf ~= encodeVarint(m.activeActions);
        
        return buf;
    }
    
    private ubyte[] encodeEnvEntry(string key, string value) @trusted {
        ubyte[] buf;
        
        buf ~= makeTag(1, WireType.LengthDelimited);
        buf ~= encodeVarint(key.length);
        buf ~= cast(ubyte[])key;
        
        buf ~= makeTag(2, WireType.LengthDelimited);
        buf ~= encodeVarint(value.length);
        buf ~= cast(ubyte[])value;
        
        return buf;
    }
    
    private ubyte[] encodeInputSpec(InputSpec input) @trusted {
        ubyte[] buf;
        
        // id
        buf ~= makeTag(1, WireType.LengthDelimited);
        buf ~= encodeVarint(32);
        buf ~= input.id.hash[];
        
        // path
        buf ~= makeTag(2, WireType.LengthDelimited);
        buf ~= encodeVarint(input.path.length);
        buf ~= cast(ubyte[])input.path;
        
        // executable
        buf ~= makeTag(3, WireType.Varint);
        buf ~= input.executable ? 0x01 : 0x00;
        
        return buf;
    }
    
    private ubyte[] encodeOutputSpec(OutputSpec output) @trusted {
        ubyte[] buf;
        
        buf ~= makeTag(1, WireType.LengthDelimited);
        buf ~= encodeVarint(output.path.length);
        buf ~= cast(ubyte[])output.path;
        
        buf ~= makeTag(2, WireType.Varint);
        buf ~= output.optional ? 0x01 : 0x00;
        
        return buf;
    }
    
    private ubyte[] encodeCapabilities(Capabilities c) @trusted {
        ubyte[] buf;
        
        buf ~= makeTag(1, WireType.Varint);
        buf ~= c.network ? 0x01 : 0x00;
        
        buf ~= makeTag(2, WireType.Varint);
        buf ~= c.writeHome ? 0x01 : 0x00;
        
        buf ~= makeTag(3, WireType.Varint);
        buf ~= c.writeTmp ? 0x01 : 0x00;
        
        buf ~= makeTag(6, WireType.Varint);
        buf ~= encodeVarint(c.maxCpu);
        
        buf ~= makeTag(7, WireType.Varint);
        buf ~= encodeVarint(c.maxMemory);
        
        buf ~= makeTag(8, WireType.Varint);
        buf ~= encodeVarint(c.timeout.total!"msecs");
        
        return buf;
    }
    
    // =========================================================================
    // Protobuf Primitives
    // =========================================================================
    
    private static ubyte makeTag(uint fieldNumber, WireType wireType) pure nothrow @safe @nogc =>
        cast(ubyte)((fieldNumber << 3) | wireType);
    
    private static ubyte[] encodeVarint(long value) @trusted {
        ubyte[] buf;
        auto uvalue = cast(ulong)value;
        
        while (uvalue >= 0x80) {
            buf ~= cast(ubyte)(uvalue | 0x80);
            uvalue >>= 7;
        }
        buf ~= cast(ubyte)uvalue;
        
        return buf;
    }
    
    private struct VarintResult {
        long value;
        size_t bytesRead;
    }
    
    private static Result!(VarintResult, string) decodeVarint(const ubyte[] data) @trusted {
        if (data.length == 0)
            return Err!(VarintResult, string)("Empty varint data");
        
        ulong result = 0;
        size_t shift = 0;
        size_t bytesRead = 0;
        
        foreach (b; data) {
            bytesRead++;
            result |= (cast(ulong)(b & 0x7F)) << shift;
            
            if ((b & 0x80) == 0)
                return Ok!(VarintResult, string)(VarintResult(cast(long)result, bytesRead));
            
            shift += 7;
            if (shift >= 64)
                return Err!(VarintResult, string)("Varint overflow");
        }
        
        return Err!(VarintResult, string)("Incomplete varint");
    }
    
    private struct TagResult {
        uint fieldNumber;
        WireType wireType;
        size_t bytesRead;
    }
    
    private static Result!(TagResult, string) decodeTag(const ubyte[] data) @trusted {
        auto varintResult = decodeVarint(data);
        if (varintResult.isErr)
            return Err!(TagResult, string)(varintResult.unwrapErr());
        
        auto tag = varintResult.unwrap().value;
        return Ok!(TagResult, string)(TagResult(
            cast(uint)(tag >> 3),
            cast(WireType)(tag & 0x07),
            varintResult.unwrap().bytesRead
        ));
    }
    
    private static Result!(size_t, string) skipField(const ubyte[] data, WireType wireType) @trusted {
        final switch (wireType) {
            case WireType.Varint:
                auto result = decodeVarint(data);
                if (result.isErr) return Err!(size_t, string)(result.unwrapErr());
                return Ok!(size_t, string)(result.unwrap().bytesRead);
                
            case WireType.Fixed64:
                if (data.length < 8) return Err!(size_t, string)("Fixed64 truncated");
                return Ok!(size_t, string)(cast(size_t)8);
                
            case WireType.LengthDelimited:
                auto lenResult = decodeVarint(data);
                if (lenResult.isErr) return Err!(size_t, string)(lenResult.unwrapErr());
                auto totalLen = lenResult.unwrap().bytesRead + cast(size_t)lenResult.unwrap().value;
                return Ok!(size_t, string)(totalLen);
                
            case WireType.Fixed32:
                if (data.length < 4) return Err!(size_t, string)("Fixed32 truncated");
                return Ok!(size_t, string)(cast(size_t)4);
        }
    }
}
