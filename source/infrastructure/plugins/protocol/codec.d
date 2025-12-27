module infrastructure.plugins.protocol.codec;

import std.json;
import std.array : appender;
import std.format : format;
import std.string : strip;
import infrastructure.plugins.protocol.types;
import infrastructure.errors;

/// JSON-RPC codec for encoding/decoding messages
struct RPCCodec {
    /// Encode request to JSON string
    static string encodeRequest(RPCRequest request) @safe {
        return request.toJSON().toString();
    }
    
    /// Decode request from JSON string
    static BuildResult!RPCRequest decodeRequest(string json) @system {
        try {
            auto parsed = parseJSON(json);
            return RPCRequest.fromJSON(parsed);
        } catch (Exception e) {
            return Err!(RPCRequest, BuildError)(
                Errors.plugin("Failed to decode JSON-RPC request: " ~ e.msg, Plugin.InvalidMessage)
                    .withContext("decoding request", "invalid JSON")
                    .withSuggestion("Check that the JSON is well-formed")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Encode response to JSON string
    static string encodeResponse(RPCResponse response) @safe {
        return response.toJSON().toString();
    }
    
    /// Decode response from JSON string
    static BuildResult!RPCResponse decodeResponse(string json) @system {
        try {
            auto parsed = parseJSON(json);
            return RPCResponse.fromJSON(parsed);
        } catch (Exception e) {
            return Err!(RPCResponse, BuildError)(
                Errors.plugin("Failed to decode JSON-RPC response: " ~ e.msg, Plugin.InvalidMessage)
                    .withContext("decoding response", "invalid JSON")
                    .withSuggestion("Check that the JSON is well-formed")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Create info request
    static RPCRequest infoRequest(long id = 1) pure @safe {
        RPCRequest req;
        req.id = id;
        req.method = "plugin.info";
        req.params = JSONValue(null);
        return req;
    }
    
    /// Create pre-hook request
    static RPCRequest preHookRequest(long id, PluginTarget target, PluginWorkspace workspace) @safe {
        RPCRequest req;
        req.id = id;
        req.method = "build.pre_hook";
        
        JSONValue params = parseJSON("{}");
        params["target"] = target.toJSON();
        params["workspace"] = workspace.toJSON();
        req.params = params;
        
        return req;
    }
    
    /// Create post-hook request
    static RPCRequest postHookRequest(
        long id,
        PluginTarget target,
        PluginWorkspace workspace,
        string[] outputs,
        bool success,
        long durationMs
    ) @safe {
        RPCRequest req;
        req.id = id;
        req.method = "build.post_hook";
        
        JSONValue params = parseJSON("{}");
        params["target"] = target.toJSON();
        params["workspace"] = workspace.toJSON();
        params["outputs"] = JSONValue(outputs);
        params["success"] = success;
        params["duration_ms"] = durationMs;
        req.params = params;
        
        return req;
    }
    
    /// Create success response
    static RPCResponse successResponse(long id, JSONValue result) pure @safe {
        return RPCResponse.success(id, result);
    }
    
    /// Create error response
    static RPCResponse errorResponse(long id, int code, string message) @safe {
        return RPCResponse.failure(id, RPCError(code, message));
    }
    
    /// Create error response with data
    static RPCResponse errorResponseWithData(long id, int code, string message, JSONValue data) @safe {
        return RPCResponse.failure(id, RPCError(code, message, data));
    }
}

/// Unit tests for codec
unittest {
    // Test request encoding/decoding
    auto req = RPCRequest();
    req.id = 42;
    req.method = "plugin.info";
    req.params = JSONValue(null);
    
    auto encoded = RPCCodec.encodeRequest(req);
    auto decoded = RPCCodec.decodeRequest(encoded);
    
    assert(decoded.isOk);
    auto decodedReq = decoded.unwrap();
    assert(decodedReq.id == 42);
    assert(decodedReq.method == "plugin.info");
}

unittest {
    // Test response encoding/decoding
    auto resp = RPCResponse.success(42, JSONValue(["result": "ok"]));
    
    auto encoded = RPCCodec.encodeResponse(resp);
    auto decoded = RPCCodec.decodeResponse(encoded);
    
    assert(decoded.isOk);
    auto decodedResp = decoded.unwrap();
    assert(decodedResp.id == 42);
    assert(decodedResp.isSuccess);
}

unittest {
    // Test error response encoding/decoding
    auto resp = RPCResponse.failure(42, RPCError(-32601, "Method not found"));
    
    auto encoded = RPCCodec.encodeResponse(resp);
    auto decoded = RPCCodec.decodeResponse(encoded);
    
    assert(decoded.isOk);
    auto decodedResp = decoded.unwrap();
    assert(decodedResp.id == 42);
    assert(decodedResp.isError);
    assert(decodedResp.error.code == -32601);
}

