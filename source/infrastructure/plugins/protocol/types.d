module infrastructure.plugins.protocol.types;

import std.json;
import std.conv : to;
import infrastructure.errors;

/// JSON-RPC 2.0 protocol version
enum JSONRPC_VERSION = "2.0";

/// Standard JSON-RPC error codes
enum RPCErrorCode {
    ParseError = -32700,
    InvalidRequest = -32600,
    MethodNotFound = -32601,
    InvalidParams = -32602,
    InternalError = -32603,
    
    // Builder-specific errors
    ToolNotFound = -32000,
    InvalidConfig = -32001,
    BuildFailed = -32002,
    Timeout = -32003,
    PluginCrashed = -32004
}

/// JSON-RPC request structure
struct RPCRequest {
    string jsonrpc = JSONRPC_VERSION;
    long id;
    string method;
    JSONValue params;
    
    /// Convert to JSON
    JSONValue toJSON() const pure @safe {
        JSONValue json = parseJSON("{}");
        json["jsonrpc"] = jsonrpc;
        json["id"] = id;
        json["method"] = method;
        json["params"] = params;
        return json;
    }
    
    /// Create from JSON
    static BuildResult!RPCRequest fromJSON(JSONValue json) @system {
        try {
            RPCRequest req;
            req.jsonrpc = json["jsonrpc"].str;
            req.id = json["id"].integer;
            req.method = json["method"].str;
            req.params = "params" in json ? json["params"] : JSONValue(null);
            
            if (req.jsonrpc != JSONRPC_VERSION)
                return Err!(RPCRequest, BuildError)(
                    Errors.plugin("Invalid JSON-RPC version: " ~ req.jsonrpc, ErrorCode.InvalidMessage)
                        .withSuggestion("Use JSON-RPC 2.0 protocol"));
            
            return Ok!(RPCRequest, BuildError)(req);
        } catch (Exception e) {
            return Err!(RPCRequest, BuildError)(
                Errors.plugin("Failed to parse RPC request: " ~ e.msg, ErrorCode.InvalidMessage));
        }
    }
}

/// JSON-RPC error structure
struct RPCError {
    int code;
    string message;
    JSONValue data;
    
    this(int code, string message) pure @safe {
        this.code = code;
        this.message = message;
        this.data = JSONValue(null);
    }
    
    this(int code, string message, JSONValue data) pure @safe {
        this.code = code;
        this.message = message;
        this.data = data;
    }
    
    /// Convert to JSON
    JSONValue toJSON() const pure @safe {
        JSONValue json = parseJSON("{}");
        json["code"] = code;
        json["message"] = message;
        if (data.type != JSONType.null_)
            json["data"] = data;
        return json;
    }
    
    /// Create from JSON
    static BuildResult!RPCError fromJSON(JSONValue json) @system {
        try {
            int code = cast(int)json["code"].integer;
            string message = json["message"].str;
            JSONValue data = "data" in json ? json["data"] : JSONValue(null);
            return Ok!(RPCError, BuildError)(RPCError(code, message, data));
        } catch (Exception e) {
            return Err!(RPCError, BuildError)(
                Errors.plugin("Failed to parse RPC error: " ~ e.msg, ErrorCode.InvalidMessage));
        }
    }
}

/// JSON-RPC response structure
struct RPCResponse {
    string jsonrpc = JSONRPC_VERSION;
    long id;
    JSONValue result;
    RPCError* error;
    
    /// Create success response
    static RPCResponse success(long id, JSONValue result) pure @safe {
        RPCResponse resp;
        resp.id = id;
        resp.result = result;
        resp.error = null;
        return resp;
    }
    
    /// Create error response
    static RPCResponse failure(long id, RPCError err) @safe {
        RPCResponse resp;
        resp.id = id;
        resp.result = JSONValue(null);
        resp.error = new RPCError(err.code, err.message, err.data);
        return resp;
    }
    
    /// Check if response is success
    bool isSuccess() const pure nothrow @nogc @safe {
        return error is null;
    }
    
    /// Check if response is error
    bool isError() const pure nothrow @nogc @safe {
        return error !is null;
    }
    
    /// Convert to JSON
    JSONValue toJSON() const @safe {
        JSONValue json = parseJSON("{}");
        json["jsonrpc"] = jsonrpc;
        json["id"] = id;
        
        if (error is null) {
            json["result"] = result;
        } else {
            json["error"] = error.toJSON();
        }
        
        return json;
    }
    
    /// Create from JSON
    static BuildResult!RPCResponse fromJSON(JSONValue json) @system {
        try {
            RPCResponse resp;
            resp.jsonrpc = json["jsonrpc"].str;
            resp.id = json["id"].integer;
            
            if (resp.jsonrpc != JSONRPC_VERSION)
                return Err!(RPCResponse, BuildError)(
                    Errors.plugin("Invalid JSON-RPC version: " ~ resp.jsonrpc, ErrorCode.InvalidMessage)
                        .withSuggestion("Use JSON-RPC 2.0 protocol"));
            
            if ("result" in json) {
                resp.result = json["result"];
                resp.error = null;
            } else if ("error" in json) {
                auto errResult = RPCError.fromJSON(json["error"]);
                if (errResult.isErr)
                    return Err!(RPCResponse, BuildError)(errResult.unwrapErr());
                auto rpcErr = errResult.unwrap();
                resp.error = new RPCError(rpcErr.code, rpcErr.message, rpcErr.data);
                resp.result = JSONValue(null);
            } else {
                return Err!(RPCResponse, BuildError)(
                    Errors.plugin("Response must have either 'result' or 'error' field", ErrorCode.InvalidMessage));
            }
            
            return Ok!(RPCResponse, BuildError)(resp);
        } catch (Exception e) {
            return Err!(RPCResponse, BuildError)(
                Errors.plugin("Failed to parse RPC response: " ~ e.msg, ErrorCode.InvalidMessage));
        }
    }
}

/// Plugin metadata structure
struct PluginInfo {
    string name;
    string version_;
    string author;
    string description;
    string homepage;
    string[] capabilities;
    string minBuilderVersion;
    string license;
    
    /// Convert to JSON
    JSONValue toJSON() const pure @safe {
        JSONValue json = parseJSON("{}");
        json["name"] = name;
        json["version"] = version_;
        json["author"] = author;
        json["description"] = description;
        json["homepage"] = homepage;
        json["capabilities"] = JSONValue(capabilities);
        json["minBuilderVersion"] = minBuilderVersion;
        json["license"] = license;
        return json;
    }
    
    /// Create from JSON
    static BuildResult!PluginInfo fromJSON(JSONValue json) @system {
        try {
            PluginInfo info;
            info.name = json["name"].str;
            info.version_ = json["version"].str;
            info.author = json["author"].str;
            info.description = json["description"].str;
            info.homepage = json["homepage"].str;
            info.minBuilderVersion = json["minBuilderVersion"].str;
            info.license = json["license"].str;
            
            // Parse capabilities array
            if ("capabilities" in json) {
                auto capsArray = json["capabilities"].array;
                info.capabilities.length = capsArray.length;
                foreach (i, cap; capsArray)
                    info.capabilities[i] = cap.str;
            }
            
            return Ok!(PluginInfo, BuildError)(info);
        } catch (Exception e) {
            return Err!(PluginInfo, BuildError)(
                Errors.plugin("Failed to parse plugin info: " ~ e.msg, ErrorCode.InvalidMessage));
        }
    }
}

/// Build target information for plugin hooks
struct PluginTarget {
    string name;
    string type;
    string language;
    string[] sources;
    string[] deps;
    JSONValue config;
    
    /// Convert to JSON
    JSONValue toJSON() const pure @safe {
        JSONValue json = parseJSON("{}");
        json["name"] = name;
        json["type"] = type;
        json["language"] = language;
        json["sources"] = JSONValue(sources);
        json["deps"] = JSONValue(deps);
        json["config"] = config;
        return json;
    }
    
    /// Create from JSON
    static BuildResult!PluginTarget fromJSON(JSONValue json) @system {
        try {
            PluginTarget target;
            target.name = json["name"].str;
            target.type = json["type"].str;
            target.language = json["language"].str;
            
            if ("sources" in json) {
                auto sourcesArray = json["sources"].array;
                target.sources.length = sourcesArray.length;
                foreach (i, src; sourcesArray)
                    target.sources[i] = src.str;
            }
            
            if ("deps" in json) {
                auto depsArray = json["deps"].array;
                target.deps.length = depsArray.length;
                foreach (i, dep; depsArray)
                    target.deps[i] = dep.str;
            }
            
            target.config = "config" in json ? json["config"] : JSONValue(null);
            
            return Ok!(PluginTarget, BuildError)(target);
        } catch (Exception e) {
            return Err!(PluginTarget, BuildError)(
                Errors.plugin("Failed to parse plugin target: " ~ e.msg, ErrorCode.InvalidMessage));
        }
    }
}

/// Workspace information for plugin hooks
struct PluginWorkspace {
    string root;
    string cacheDir;
    string builderVersion;
    JSONValue config;
    
    /// Convert to JSON
    JSONValue toJSON() const pure @safe {
        JSONValue json = parseJSON("{}");
        json["root"] = root;
        json["cache_dir"] = cacheDir;
        json["builder_version"] = builderVersion;
        json["config"] = config;
        return json;
    }
}

/// Build hook result
struct HookResult {
    bool success;
    PluginTarget* modifiedTarget;
    string[] artifacts;
    string[] logs;
    
    /// Create success result
    static HookResult succeed(string[] logs = []) pure @safe {
        HookResult result;
        result.success = true;
        result.logs = logs;
        return result;
    }
    
    /// Create failure result
    static HookResult fail(string[] logs) pure @safe {
        HookResult result;
        result.success = false;
        result.logs = logs;
        return result;
    }
    
    /// Convert to JSON
    JSONValue toJSON() const @safe {
        JSONValue json = parseJSON("{}");
        json["success"] = success;
        json["artifacts"] = JSONValue(artifacts);
        json["logs"] = JSONValue(logs);
        
        if (modifiedTarget !is null) {
            json["modified_target"] = modifiedTarget.toJSON();
        }
        
        return json;
    }
    
    /// Create from JSON
    static BuildResult!HookResult fromJSON(JSONValue json) @system {
        try {
            HookResult result;
            result.success = json["success"].boolean;
            
            if ("artifacts" in json) {
                auto artifactsArray = json["artifacts"].array;
                result.artifacts.length = artifactsArray.length;
                foreach (i, art; artifactsArray)
                    result.artifacts[i] = art.str;
            }
            
            if ("logs" in json) {
                auto logsArray = json["logs"].array;
                result.logs.length = logsArray.length;
                foreach (i, log; logsArray)
                    result.logs[i] = log.str;
            }
            
            if ("modified_target" in json) {
                auto targetResult = PluginTarget.fromJSON(json["modified_target"]);
                if (targetResult.isErr)
                    return Err!(HookResult, BuildError)(targetResult.unwrapErr());
                auto target = targetResult.unwrap();
                result.modifiedTarget = new PluginTarget;
                *result.modifiedTarget = target;
            }
            
            return Ok!(HookResult, BuildError)(result);
        } catch (Exception e) {
            return Err!(HookResult, BuildError)(
                Errors.plugin("Failed to parse hook result: " ~ e.msg, ErrorCode.InvalidMessage));
        }
    }
}

