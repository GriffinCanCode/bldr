module engine.distributed.protocol.reapi_v2.codec;

import std.datetime : Duration, SysTime, Clock;
import std.bitmanip : write, read;
import std.conv : to;
import engine.distributed.protocol.reapi_v2.types;
import infrastructure.errors;

/**
 * REAPI v2 Wire Format Codec
 * 
 * Implements protobuf-compatible binary encoding for REAPI messages.
 * This enables wire-level compatibility with standard REAPI implementations
 * without requiring the protobuf library.
 * 
 * Wire format follows protobuf encoding rules:
 * - Varints for integers
 * - Length-delimited for strings/bytes
 * - Packed repeated fields
 */
struct ReapiV2Codec {
    /// Protobuf wire types
    enum WireType : ubyte {
        Varint = 0,
        Fixed64 = 1,
        LengthDelimited = 2,
        StartGroup = 3,  // Deprecated
        EndGroup = 4,    // Deprecated
        Fixed32 = 5
    }
    
    // =========================================================================
    // Encoding
    // =========================================================================
    
    /// Encode Digest message
    static ubyte[] encodeDigest(ReapiDigest digest) @trusted {
        ubyte[] buf;
        buf.reserve(128);
        
        // Field 1: hash (string in proto, but we use bytes)
        if (digest.hash.length > 0) {
            buf ~= makeTag(1, WireType.LengthDelimited);
            auto hexStr = digest.hashString();
            buf ~= encodeVarint(hexStr.length);
            buf ~= cast(ubyte[])hexStr;
        }
        
        // Field 2: size_bytes (int64)
        if (digest.sizeBytes != 0) {
            buf ~= makeTag(2, WireType.Varint);
            buf ~= encodeVarint(digest.sizeBytes);
        }
        
        return buf;
    }
    
    /// Encode Platform message
    static ubyte[] encodePlatform(ReapiPlatform platform) @trusted {
        ubyte[] buf;
        buf.reserve(256);
        
        // Field 1: properties (repeated Property)
        foreach (prop; platform.properties) {
            buf ~= makeTag(1, WireType.LengthDelimited);
            auto propBuf = encodeProperty(prop);
            buf ~= encodeVarint(propBuf.length);
            buf ~= propBuf;
        }
        
        return buf;
    }
    
    /// Encode Property message
    static ubyte[] encodeProperty(ReapiProperty prop) @trusted {
        ubyte[] buf;
        buf.reserve(64);
        
        // Field 1: name
        if (prop.name.length > 0) {
            buf ~= makeTag(1, WireType.LengthDelimited);
            buf ~= encodeVarint(prop.name.length);
            buf ~= cast(ubyte[])prop.name;
        }
        
        // Field 2: value
        if (prop.value.length > 0) {
            buf ~= makeTag(2, WireType.LengthDelimited);
            buf ~= encodeVarint(prop.value.length);
            buf ~= cast(ubyte[])prop.value;
        }
        
        return buf;
    }
    
    /// Encode Command message
    static ubyte[] encodeCommand(ReapiCommand cmd) @trusted {
        ubyte[] buf;
        buf.reserve(1024);
        
        // Field 1: arguments (repeated string)
        foreach (arg; cmd.arguments) {
            buf ~= makeTag(1, WireType.LengthDelimited);
            buf ~= encodeVarint(arg.length);
            buf ~= cast(ubyte[])arg;
        }
        
        // Field 2: environment_variables (repeated EnvironmentVariable)
        foreach (env; cmd.environmentVariables) {
            buf ~= makeTag(2, WireType.LengthDelimited);
            auto envBuf = encodeEnvVar(env);
            buf ~= encodeVarint(envBuf.length);
            buf ~= envBuf;
        }
        
        // Field 3: output_files
        foreach (path; cmd.outputFiles) {
            buf ~= makeTag(3, WireType.LengthDelimited);
            buf ~= encodeVarint(path.length);
            buf ~= cast(ubyte[])path;
        }
        
        // Field 4: output_directories
        foreach (path; cmd.outputDirectories) {
            buf ~= makeTag(4, WireType.LengthDelimited);
            buf ~= encodeVarint(path.length);
            buf ~= cast(ubyte[])path;
        }
        
        // Field 5: output_paths
        foreach (path; cmd.outputPaths) {
            buf ~= makeTag(5, WireType.LengthDelimited);
            buf ~= encodeVarint(path.length);
            buf ~= cast(ubyte[])path;
        }
        
        // Field 6: platform
        if (cmd.platform.properties.length > 0) {
            buf ~= makeTag(6, WireType.LengthDelimited);
            auto platBuf = encodePlatform(cmd.platform);
            buf ~= encodeVarint(platBuf.length);
            buf ~= platBuf;
        }
        
        // Field 7: working_directory
        if (cmd.workingDirectory.length > 0) {
            buf ~= makeTag(7, WireType.LengthDelimited);
            buf ~= encodeVarint(cmd.workingDirectory.length);
            buf ~= cast(ubyte[])cmd.workingDirectory;
        }
        
        return buf;
    }
    
    /// Encode EnvironmentVariable message
    static ubyte[] encodeEnvVar(ReapiEnvVar env) @trusted {
        ubyte[] buf;
        buf.reserve(128);
        
        // Field 1: name
        buf ~= makeTag(1, WireType.LengthDelimited);
        buf ~= encodeVarint(env.name.length);
        buf ~= cast(ubyte[])env.name;
        
        // Field 2: value
        buf ~= makeTag(2, WireType.LengthDelimited);
        buf ~= encodeVarint(env.value.length);
        buf ~= cast(ubyte[])env.value;
        
        return buf;
    }
    
    /// Encode Action message
    static ubyte[] encodeAction(ReapiAction action) @trusted {
        ubyte[] buf;
        buf.reserve(512);
        
        // Field 1: command_digest
        buf ~= makeTag(1, WireType.LengthDelimited);
        auto cmdDigest = encodeDigest(action.commandDigest);
        buf ~= encodeVarint(cmdDigest.length);
        buf ~= cmdDigest;
        
        // Field 2: input_root_digest
        buf ~= makeTag(2, WireType.LengthDelimited);
        auto inputDigest = encodeDigest(action.inputRootDigest);
        buf ~= encodeVarint(inputDigest.length);
        buf ~= inputDigest;
        
        // Field 3: timeout (Duration as proto Duration)
        if (action.timeout > Duration.zero) {
            buf ~= makeTag(3, WireType.LengthDelimited);
            auto durationBuf = encodeDuration(action.timeout);
            buf ~= encodeVarint(durationBuf.length);
            buf ~= durationBuf;
        }
        
        // Field 4: do_not_cache
        if (action.doNotCache) {
            buf ~= makeTag(4, WireType.Varint);
            buf ~= 0x01;
        }
        
        // Field 5: salt
        if (action.salt.length > 0) {
            buf ~= makeTag(5, WireType.LengthDelimited);
            buf ~= encodeVarint(action.salt.length);
            buf ~= cast(ubyte[])action.salt;
        }
        
        return buf;
    }
    
    /// Encode Duration (google.protobuf.Duration)
    static ubyte[] encodeDuration(Duration d) @trusted {
        ubyte[] buf;
        
        auto totalNsecs = d.total!"nsecs";
        auto secs = totalNsecs / 1_000_000_000;
        auto nanos = cast(int)(totalNsecs % 1_000_000_000);
        
        // Field 1: seconds
        if (secs != 0) {
            buf ~= makeTag(1, WireType.Varint);
            buf ~= encodeVarint(secs);
        }
        
        // Field 2: nanos
        if (nanos != 0) {
            buf ~= makeTag(2, WireType.Varint);
            buf ~= encodeVarint(nanos);
        }
        
        return buf;
    }
    
    /// Encode ActionResult message
    static ubyte[] encodeActionResult(ReapiActionResult result) @trusted {
        ubyte[] buf;
        buf.reserve(4096);
        
        // Field 1: output_files (repeated OutputFile)
        foreach (file; result.outputFiles) {
            buf ~= makeTag(1, WireType.LengthDelimited);
            auto fileBuf = encodeOutputFile(file);
            buf ~= encodeVarint(fileBuf.length);
            buf ~= fileBuf;
        }
        
        // Field 4: output_directories
        foreach (dir; result.outputDirectories) {
            buf ~= makeTag(4, WireType.LengthDelimited);
            auto dirBuf = encodeOutputDirectory(dir);
            buf ~= encodeVarint(dirBuf.length);
            buf ~= dirBuf;
        }
        
        // Field 6: exit_code
        buf ~= makeTag(6, WireType.Varint);
        buf ~= encodeVarint(result.exitCode);
        
        // Field 7: stdout_raw
        if (result.stdoutRaw.length > 0) {
            buf ~= makeTag(7, WireType.LengthDelimited);
            buf ~= encodeVarint(result.stdoutRaw.length);
            buf ~= result.stdoutRaw;
        }
        
        // Field 8: stdout_digest
        if (result.stdoutDigest.hash.length > 0) {
            buf ~= makeTag(8, WireType.LengthDelimited);
            auto digestBuf = encodeDigest(result.stdoutDigest);
            buf ~= encodeVarint(digestBuf.length);
            buf ~= digestBuf;
        }
        
        // Field 9: stderr_raw
        if (result.stderrRaw.length > 0) {
            buf ~= makeTag(9, WireType.LengthDelimited);
            buf ~= encodeVarint(result.stderrRaw.length);
            buf ~= result.stderrRaw;
        }
        
        // Field 10: stderr_digest
        if (result.stderrDigest.hash.length > 0) {
            buf ~= makeTag(10, WireType.LengthDelimited);
            auto digestBuf = encodeDigest(result.stderrDigest);
            buf ~= encodeVarint(digestBuf.length);
            buf ~= digestBuf;
        }
        
        return buf;
    }
    
    /// Encode OutputFile message
    static ubyte[] encodeOutputFile(ReapiOutputFile file) @trusted {
        ubyte[] buf;
        buf.reserve(256);
        
        // Field 1: path
        buf ~= makeTag(1, WireType.LengthDelimited);
        buf ~= encodeVarint(file.path.length);
        buf ~= cast(ubyte[])file.path;
        
        // Field 2: digest
        buf ~= makeTag(2, WireType.LengthDelimited);
        auto digestBuf = encodeDigest(file.digest);
        buf ~= encodeVarint(digestBuf.length);
        buf ~= digestBuf;
        
        // Field 4: is_executable
        if (file.isExecutable) {
            buf ~= makeTag(4, WireType.Varint);
            buf ~= 0x01;
        }
        
        // Field 5: contents (inline for small files)
        if (file.contents.length > 0) {
            buf ~= makeTag(5, WireType.LengthDelimited);
            buf ~= encodeVarint(file.contents.length);
            buf ~= file.contents;
        }
        
        return buf;
    }
    
    /// Encode OutputDirectory message
    static ubyte[] encodeOutputDirectory(ReapiOutputDirectory dir) @trusted {
        ubyte[] buf;
        buf.reserve(128);
        
        // Field 1: path
        buf ~= makeTag(1, WireType.LengthDelimited);
        buf ~= encodeVarint(dir.path.length);
        buf ~= cast(ubyte[])dir.path;
        
        // Field 2: tree_digest
        buf ~= makeTag(2, WireType.LengthDelimited);
        auto digestBuf = encodeDigest(dir.treeDigest);
        buf ~= encodeVarint(digestBuf.length);
        buf ~= digestBuf;
        
        return buf;
    }
    
    /// Encode ExecuteRequest message
    static ubyte[] encodeExecuteRequest(ReapiExecuteRequest req) @trusted {
        ubyte[] buf;
        buf.reserve(512);
        
        // Field 1: instance_name
        if (req.instanceName.length > 0) {
            buf ~= makeTag(1, WireType.LengthDelimited);
            buf ~= encodeVarint(req.instanceName.length);
            buf ~= cast(ubyte[])req.instanceName;
        }
        
        // Field 2: skip_cache_lookup
        if (req.skipCacheLookup) {
            buf ~= makeTag(2, WireType.Varint);
            buf ~= 0x01;
        }
        
        // Field 3: action_digest
        buf ~= makeTag(3, WireType.LengthDelimited);
        auto digestBuf = encodeDigest(req.actionDigest);
        buf ~= encodeVarint(digestBuf.length);
        buf ~= digestBuf;
        
        return buf;
    }
    
    /// Encode ExecuteResponse message
    static ubyte[] encodeExecuteResponse(ReapiExecuteResponse resp) @trusted {
        ubyte[] buf;
        buf.reserve(4096);
        
        // Field 1: result
        buf ~= makeTag(1, WireType.LengthDelimited);
        auto resultBuf = encodeActionResult(resp.result);
        buf ~= encodeVarint(resultBuf.length);
        buf ~= resultBuf;
        
        // Field 2: cached_result
        if (resp.cachedResult) {
            buf ~= makeTag(2, WireType.Varint);
            buf ~= 0x01;
        }
        
        // Field 3: status
        if (!resp.status.isOk) {
            buf ~= makeTag(3, WireType.LengthDelimited);
            auto statusBuf = encodeStatus(resp.status);
            buf ~= encodeVarint(statusBuf.length);
            buf ~= statusBuf;
        }
        
        return buf;
    }
    
    /// Encode Status message (google.rpc.Status)
    static ubyte[] encodeStatus(ReapiStatus status) @trusted {
        ubyte[] buf;
        
        // Field 1: code
        buf ~= makeTag(1, WireType.Varint);
        buf ~= encodeVarint(status.code);
        
        // Field 2: message
        if (status.message.length > 0) {
            buf ~= makeTag(2, WireType.LengthDelimited);
            buf ~= encodeVarint(status.message.length);
            buf ~= cast(ubyte[])status.message;
        }
        
        return buf;
    }
    
    /// Encode ServerCapabilities message
    static ubyte[] encodeServerCapabilities(ReapiServerCapabilities caps) @trusted {
        ubyte[] buf;
        buf.reserve(512);
        
        // Field 1: cache_capabilities
        buf ~= makeTag(1, WireType.LengthDelimited);
        auto cacheBuf = encodeCacheCapabilities(caps.cacheCapabilities);
        buf ~= encodeVarint(cacheBuf.length);
        buf ~= cacheBuf;
        
        // Field 2: execution_capabilities
        buf ~= makeTag(2, WireType.LengthDelimited);
        auto execBuf = encodeExecutionCapabilities(caps.executionCapabilities);
        buf ~= encodeVarint(execBuf.length);
        buf ~= execBuf;
        
        // Field 4: low_api_version
        if (caps.lowApiVersion.length > 0) {
            buf ~= makeTag(4, WireType.LengthDelimited);
            buf ~= encodeVarint(caps.lowApiVersion.length);
            buf ~= cast(ubyte[])caps.lowApiVersion;
        }
        
        // Field 5: high_api_version
        if (caps.highApiVersion.length > 0) {
            buf ~= makeTag(5, WireType.LengthDelimited);
            buf ~= encodeVarint(caps.highApiVersion.length);
            buf ~= cast(ubyte[])caps.highApiVersion;
        }
        
        return buf;
    }
    
    /// Encode CacheCapabilities message
    static ubyte[] encodeCacheCapabilities(ReapiCacheCapabilities caps) @trusted {
        ubyte[] buf;
        
        // Field 1: digest_functions (repeated enum as packed)
        if (caps.digestFunctions.length > 0) {
            buf ~= makeTag(1, WireType.LengthDelimited);
            ubyte[] packed;
            foreach (f; caps.digestFunctions)
                packed ~= encodeVarint(f);
            buf ~= encodeVarint(packed.length);
            buf ~= packed;
        }
        
        // Field 4: max_batch_total_size_bytes
        if (caps.maxBatchTotalSizeBytes > 0) {
            buf ~= makeTag(4, WireType.Varint);
            buf ~= encodeVarint(caps.maxBatchTotalSizeBytes);
        }
        
        // Field 5: symlink_absolute_path_strategy
        if (caps.symlinkAbsolutePathStrategy != SymlinkAbsolutePathStrategy.Unknown) {
            buf ~= makeTag(5, WireType.Varint);
            buf ~= encodeVarint(caps.symlinkAbsolutePathStrategy);
        }
        
        return buf;
    }
    
    /// Encode ExecutionCapabilities message
    static ubyte[] encodeExecutionCapabilities(ReapiExecutionCapabilities caps) @trusted {
        ubyte[] buf;
        
        // Field 1: digest_function
        if (caps.digestFunction != DigestFunction.Unknown) {
            buf ~= makeTag(1, WireType.Varint);
            buf ~= encodeVarint(caps.digestFunction);
        }
        
        // Field 2: exec_enabled
        if (caps.execEnabled) {
            buf ~= makeTag(2, WireType.Varint);
            buf ~= 0x01;
        }
        
        return buf;
    }
    
    // =========================================================================
    // Decoding
    // =========================================================================
    
    /// Decode Digest message
    static Result!(ReapiDigest, string) decodeDigest(const ubyte[] data) @trusted {
        ReapiDigest digest;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto tagResult = decodeTag(data[offset .. $]);
            if (tagResult.isErr) return Err!(ReapiDigest, string)(tagResult.unwrapErr());
            
            auto tag = tagResult.unwrap();
            offset += tag.bytesRead;
            
            switch (tag.fieldNumber) {
                case 1:  // hash (string as hex)
                    auto lenResult = decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) return Err!(ReapiDigest, string)(lenResult.unwrapErr());
                    offset += lenResult.unwrap().bytesRead;
                    
                    auto strLen = cast(size_t)lenResult.unwrap().value;
                    if (offset + strLen > data.length)
                        return Err!(ReapiDigest, string)("Hash string truncated");
                    
                    auto hexStr = cast(string)data[offset .. offset + strLen];
                    digest = ReapiDigest.fromHex(hexStr, digest.sizeBytes);
                    offset += strLen;
                    break;
                    
                case 2:  // size_bytes
                    auto valResult = decodeVarint(data[offset .. $]);
                    if (valResult.isErr) return Err!(ReapiDigest, string)(valResult.unwrapErr());
                    offset += valResult.unwrap().bytesRead;
                    digest.sizeBytes = valResult.unwrap().value;
                    break;
                    
                default:
                    // Skip unknown field
                    auto skipResult = skipField(data[offset .. $], tag.wireType);
                    if (skipResult.isErr) return Err!(ReapiDigest, string)(skipResult.unwrapErr());
                    offset += skipResult.unwrap();
                    break;
            }
        }
        
        return Ok!(ReapiDigest, string)(digest);
    }
    
    /// Decode ActionResult message
    static Result!(ReapiActionResult, string) decodeActionResult(const ubyte[] data) @trusted {
        ReapiActionResult result;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto tagResult = decodeTag(data[offset .. $]);
            if (tagResult.isErr) return Err!(ReapiActionResult, string)(tagResult.unwrapErr());
            
            auto tag = tagResult.unwrap();
            offset += tag.bytesRead;
            
            switch (tag.fieldNumber) {
                case 1:  // output_files
                    auto lenResult = decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) return Err!(ReapiActionResult, string)(lenResult.unwrapErr());
                    offset += lenResult.unwrap().bytesRead;
                    
                    auto msgLen = cast(size_t)lenResult.unwrap().value;
                    auto fileResult = decodeOutputFile(data[offset .. offset + msgLen]);
                    if (fileResult.isErr) return Err!(ReapiActionResult, string)(fileResult.unwrapErr());
                    result.outputFiles ~= fileResult.unwrap();
                    offset += msgLen;
                    break;
                    
                case 6:  // exit_code
                    auto valResult = decodeVarint(data[offset .. $]);
                    if (valResult.isErr) return Err!(ReapiActionResult, string)(valResult.unwrapErr());
                    offset += valResult.unwrap().bytesRead;
                    result.exitCode = cast(int)valResult.unwrap().value;
                    break;
                    
                case 7:  // stdout_raw
                    auto lenResult = decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) return Err!(ReapiActionResult, string)(lenResult.unwrapErr());
                    offset += lenResult.unwrap().bytesRead;
                    
                    auto strLen = cast(size_t)lenResult.unwrap().value;
                    result.stdoutRaw = data[offset .. offset + strLen].dup;
                    offset += strLen;
                    break;
                    
                case 9:  // stderr_raw
                    auto lenResult = decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) return Err!(ReapiActionResult, string)(lenResult.unwrapErr());
                    offset += lenResult.unwrap().bytesRead;
                    
                    auto strLen = cast(size_t)lenResult.unwrap().value;
                    result.stderrRaw = data[offset .. offset + strLen].dup;
                    offset += strLen;
                    break;
                    
                default:
                    // Skip unknown field
                    auto skipResult = skipField(data[offset .. $], tag.wireType);
                    if (skipResult.isErr) return Err!(ReapiActionResult, string)(skipResult.unwrapErr());
                    offset += skipResult.unwrap();
                    break;
            }
        }
        
        return Ok!(ReapiActionResult, string)(result);
    }
    
    /// Decode OutputFile message
    static Result!(ReapiOutputFile, string) decodeOutputFile(const ubyte[] data) @trusted {
        ReapiOutputFile file;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto tagResult = decodeTag(data[offset .. $]);
            if (tagResult.isErr) return Err!(ReapiOutputFile, string)(tagResult.unwrapErr());
            
            auto tag = tagResult.unwrap();
            offset += tag.bytesRead;
            
            switch (tag.fieldNumber) {
                case 1:  // path
                    auto lenResult = decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) return Err!(ReapiOutputFile, string)(lenResult.unwrapErr());
                    offset += lenResult.unwrap().bytesRead;
                    
                    auto strLen = cast(size_t)lenResult.unwrap().value;
                    file.path = cast(string)data[offset .. offset + strLen];
                    offset += strLen;
                    break;
                    
                case 2:  // digest
                    auto lenResult = decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) return Err!(ReapiOutputFile, string)(lenResult.unwrapErr());
                    offset += lenResult.unwrap().bytesRead;
                    
                    auto msgLen = cast(size_t)lenResult.unwrap().value;
                    auto digestResult = decodeDigest(data[offset .. offset + msgLen]);
                    if (digestResult.isErr) return Err!(ReapiOutputFile, string)(digestResult.unwrapErr());
                    file.digest = digestResult.unwrap();
                    offset += msgLen;
                    break;
                    
                case 4:  // is_executable
                    auto valResult = decodeVarint(data[offset .. $]);
                    if (valResult.isErr) return Err!(ReapiOutputFile, string)(valResult.unwrapErr());
                    offset += valResult.unwrap().bytesRead;
                    file.isExecutable = valResult.unwrap().value != 0;
                    break;
                    
                case 5:  // contents
                    auto lenResult = decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) return Err!(ReapiOutputFile, string)(lenResult.unwrapErr());
                    offset += lenResult.unwrap().bytesRead;
                    
                    auto contentLen = cast(size_t)lenResult.unwrap().value;
                    file.contents = data[offset .. offset + contentLen].dup;
                    offset += contentLen;
                    break;
                    
                default:
                    auto skipResult = skipField(data[offset .. $], tag.wireType);
                    if (skipResult.isErr) return Err!(ReapiOutputFile, string)(skipResult.unwrapErr());
                    offset += skipResult.unwrap();
                    break;
            }
        }
        
        return Ok!(ReapiOutputFile, string)(file);
    }
    
    /// Decode ExecuteResponse message
    static Result!(ReapiExecuteResponse, string) decodeExecuteResponse(const ubyte[] data) @trusted {
        ReapiExecuteResponse resp;
        size_t offset = 0;
        
        while (offset < data.length) {
            auto tagResult = decodeTag(data[offset .. $]);
            if (tagResult.isErr) return Err!(ReapiExecuteResponse, string)(tagResult.unwrapErr());
            
            auto tag = tagResult.unwrap();
            offset += tag.bytesRead;
            
            switch (tag.fieldNumber) {
                case 1:  // result
                    auto lenResult = decodeVarint(data[offset .. $]);
                    if (lenResult.isErr) return Err!(ReapiExecuteResponse, string)(lenResult.unwrapErr());
                    offset += lenResult.unwrap().bytesRead;
                    
                    auto msgLen = cast(size_t)lenResult.unwrap().value;
                    auto resultParse = decodeActionResult(data[offset .. offset + msgLen]);
                    if (resultParse.isErr) return Err!(ReapiExecuteResponse, string)(resultParse.unwrapErr());
                    resp.result = resultParse.unwrap();
                    offset += msgLen;
                    break;
                    
                case 2:  // cached_result
                    auto valResult = decodeVarint(data[offset .. $]);
                    if (valResult.isErr) return Err!(ReapiExecuteResponse, string)(valResult.unwrapErr());
                    offset += valResult.unwrap().bytesRead;
                    resp.cachedResult = valResult.unwrap().value != 0;
                    break;
                    
                default:
                    auto skipResult = skipField(data[offset .. $], tag.wireType);
                    if (skipResult.isErr) return Err!(ReapiExecuteResponse, string)(skipResult.unwrapErr());
                    offset += skipResult.unwrap();
                    break;
            }
        }
        
        return Ok!(ReapiExecuteResponse, string)(resp);
    }
    
    // =========================================================================
    // Primitive Encoding/Decoding
    // =========================================================================
    
    /// Make field tag (field_number << 3 | wire_type)
    package static ubyte makeTag(uint fieldNumber, WireType wireType) pure nothrow @safe @nogc =>
        cast(ubyte)((fieldNumber << 3) | wireType);
    
    /// Encode unsigned varint (base-128)
    static ubyte[] encodeVarint(long value) @trusted {
        ubyte[] buf;
        auto uvalue = cast(ulong)value;
        
        while (uvalue >= 0x80) {
            buf ~= cast(ubyte)(uvalue | 0x80);
            uvalue >>= 7;
        }
        buf ~= cast(ubyte)uvalue;
        
        return buf;
    }
    
    /// Varint decode result
    struct VarintResult {
        long value;
        size_t bytesRead;
    }
    
    /// Decode unsigned varint
    static Result!(VarintResult, string) decodeVarint(const ubyte[] data) @trusted {
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
    
    /// Tag decode result
    struct TagResult {
        uint fieldNumber;
        WireType wireType;
        size_t bytesRead;
    }
    
    /// Decode field tag
    static Result!(TagResult, string) decodeTag(const ubyte[] data) @trusted {
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
    
    /// Skip unknown field
    static Result!(size_t, string) skipField(const ubyte[] data, WireType wireType) @trusted {
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
                
            case WireType.StartGroup:
            case WireType.EndGroup:
                return Err!(size_t, string)("Groups not supported");
                
            case WireType.Fixed32:
                if (data.length < 4) return Err!(size_t, string)("Fixed32 truncated");
                return Ok!(size_t, string)(cast(size_t)4);
        }
    }
}

