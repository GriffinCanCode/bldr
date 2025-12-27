module infrastructure.plugins.sdk.templates;

import std.file;
import std.path;
import std.string : replace;
import infrastructure.errors;
import infrastructure.utils.logging;

/// Plugin template language
enum TemplateLanguage {
    D,
    Python,
    Go,
    Rust
}

/// Plugin template generator
class TemplateGenerator {
    /// Create new plugin from template
    static VoidBuildResult create(
        string pluginName,
        TemplateLanguage language,
        string targetDir = "."
    ) @system {
        auto pluginDir = buildPath(targetDir, "builder-plugin-" ~ pluginName);
        
        // Check if directory exists
        if (exists(pluginDir)) {
            return VoidBuildResult.err(
                Errors.plugin("Plugin directory already exists: " ~ pluginDir, Config.InvalidInput)
                    .withSuggestion("Choose a different name or remove the existing directory")
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        // Create directory structure
        try {
            mkdirRecurse(pluginDir);
            
            final switch (language) {
                case TemplateLanguage.D:
                    createDTemplate(pluginName, pluginDir);
                    break;
                case TemplateLanguage.Python:
                    createPythonTemplate(pluginName, pluginDir);
                    break;
                case TemplateLanguage.Go:
                    createGoTemplate(pluginName, pluginDir);
                    break;
                case TemplateLanguage.Rust:
                    createRustTemplate(pluginName, pluginDir);
                    break;
            }
            
            structuredLog.info("plugin_template_created_").field("detail", "Plugin template created: " ~ pluginDir).emit();
            structuredLog.info("next_steps").emit();
            structuredLog.info("__cd_").field("detail", "  cd " ~ pluginDir).emit();
            structuredLog.info("___implement_your_plugin_logic").emit();
            structuredLog.info("___build_and_test").emit();
            structuredLog.info("___create_homebrew_formula").emit();
            
            return Ok!BuildError();
        } catch (Exception e) {
            return VoidBuildResult.err(
                Errors.plugin("Failed to create plugin template: " ~ e.msg, IO.FileWriteFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Create D language template
    private static void createDTemplate(string name, string dir) @system {
        // source/app.d
        mkdirRecurse(buildPath(dir, "source"));
        auto appCode = getDAppTemplate(name);
        std.file.write(buildPath(dir, "source", "app.d"), appCode);
        
        // dub.json
        auto dubJson = getDubJsonTemplate(name);
        std.file.write(buildPath(dir, "dub.json"), dubJson);
        
        // README.md
        auto readme = getReadmeTemplate(name, "D", "dub build");
        std.file.write(buildPath(dir, "README.md"), readme);
        
        // LICENSE
        std.file.write(buildPath(dir, "LICENSE"), getLicenseTemplate());
        
        // .gitignore
        std.file.write(buildPath(dir, ".gitignore"), getDGitignoreTemplate());
    }
    
    /// Create Python template
    private static void createPythonTemplate(string name, string dir) @system {
        // main.py
        auto mainCode = getPythonTemplate(name);
        std.file.write(buildPath(dir, "builder-plugin-" ~ name), mainCode);
        
        // Make executable
        version(Posix) {
            import core.sys.posix.sys.stat;
            import std.string : toStringz;
            
            auto path = buildPath(dir, "builder-plugin-" ~ name);
            chmod(path.toStringz(), S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH);
        }
        
        // README.md
        auto readme = getReadmeTemplate(name, "Python", "chmod +x builder-plugin-" ~ name);
        std.file.write(buildPath(dir, "README.md"), readme);
        
        // LICENSE
        std.file.write(buildPath(dir, "LICENSE"), getLicenseTemplate());
    }
    
    /// Create Go template
    private static void createGoTemplate(string name, string dir) @system {
        // main.go
        auto mainCode = getGoTemplate(name);
        std.file.write(buildPath(dir, "main.go"), mainCode);
        
        // go.mod
        auto goMod = getGoModTemplate(name);
        std.file.write(buildPath(dir, "go.mod"), goMod);
        
        // README.md
        auto readme = getReadmeTemplate(name, "Go", "go build -o builder-plugin-" ~ name);
        std.file.write(buildPath(dir, "README.md"), readme);
        
        // LICENSE
        std.file.write(buildPath(dir, "LICENSE"), getLicenseTemplate());
    }
    
    /// Create Rust template
    private static void createRustTemplate(string name, string dir) @system {
        // src/main.rs
        mkdirRecurse(buildPath(dir, "src"));
        auto mainCode = getRustTemplate(name);
        std.file.write(buildPath(dir, "src", "main.rs"), mainCode);
        
        // Cargo.toml
        auto cargoToml = getCargoTomlTemplate(name);
        std.file.write(buildPath(dir, "Cargo.toml"), cargoToml);
        
        // README.md
        auto readme = getReadmeTemplate(name, "Rust", "cargo build --release");
        std.file.write(buildPath(dir, "README.md"), readme);
        
        // LICENSE
        std.file.write(buildPath(dir, "LICENSE"), getLicenseTemplate());
    }
}

// Template content functions

private string getDAppTemplate(string name) pure @safe {
    return `import std.stdio;
import std.json;

struct PluginInfo {
    string name = "` ~ name ~ `";
    string version_ = "1.0.0";
    string author = "Griffin";
    string description = "` ~ name ~ ` plugin for Builder";
    string homepage = "https://github.com/GriffinCanCode/builder-plugin-` ~ name ~ `";
    string[] capabilities = ["build.pre_hook", "build.post_hook"];
    string minBuilderVersion = "1.0.0";
    string license = "MIT";
}

void main() {
    foreach (line; stdin.byLine()) {
        try {
            auto request = parseJSON(cast(string)line);
            auto response = handleRequest(request);
            writeln(response.toJSON());
            stdout.flush();
        } catch (Exception e) {
            writeError(e.msg);
        }
    }
}

JSONValue handleRequest(JSONValue request) {
    string method = request["method"].str;
    long id = request["id"].integer;
    
    switch (method) {
        case "plugin.info":
            return handleInfo(id);
        case "build.pre_hook":
            return handlePreHook(id, request["params"]);
        case "build.post_hook":
            return handlePostHook(id, request["params"]);
        default:
            return errorResponse(id, -32601, "Method not found: " ~ method);
    }
}

JSONValue handleInfo(long id) {
    auto info = PluginInfo();
    return JSONValue([
        "jsonrpc": "2.0",
        "id": JSONValue(id),
        "result": JSONValue([
            "name": info.name,
            "version": info.version_,
            "author": info.author,
            "description": info.description,
            "homepage": info.homepage,
            "capabilities": JSONValue(info.capabilities),
            "minBuilderVersion": info.minBuilderVersion,
            "license": info.license
        ])
    ]);
}

JSONValue handlePreHook(long id, JSONValue params) {
    // TODO: Implement your pre-build logic here
    return JSONValue([
        "jsonrpc": "2.0",
        "id": JSONValue(id),
        "result": JSONValue([
            "success": true,
            "logs": JSONValue(["Pre-build hook executed"])
        ])
    ]);
}

JSONValue handlePostHook(long id, JSONValue params) {
    // TODO: Implement your post-build logic here
    return JSONValue([
        "jsonrpc": "2.0",
        "id": JSONValue(id),
        "result": JSONValue([
            "success": true,
            "logs": JSONValue(["Post-build hook executed"])
        ])
    ]);
}

JSONValue errorResponse(long id, int code, string message) {
    return JSONValue([
        "jsonrpc": "2.0",
        "id": JSONValue(id),
        "error": JSONValue([
            "code": code,
            "message": message
        ])
    ]);
}

void writeError(string msg) {
    stderr.writeln("Error: ", msg);
}
`;
}

private string getDubJsonTemplate(string name) pure @safe {
    return `{
    "name": "builder-plugin-` ~ name ~ `",
    "description": "Builder plugin: ` ~ name ~ `",
    "authors": ["Griffin"],
    "license": "MIT",
    "targetType": "executable",
    "targetName": "builder-plugin-` ~ name ~ `",
    "sourcePaths": ["source"],
    "importPaths": ["source"],
    "buildTypes": {
        "release": {
            "buildOptions": ["releaseMode", "inline", "optimize"]
        }
    }
}
`;
}

private string getPythonTemplate(string name) pure @safe {
    return `#!/usr/bin/env python3
import json
import sys

PLUGIN_INFO = {
    "name": "` ~ name ~ `",
    "version": "1.0.0",
    "author": "Griffin",
    "description": "` ~ name ~ ` plugin for Builder",
    "homepage": "https://github.com/GriffinCanCode/builder-plugin-` ~ name ~ `",
    "capabilities": ["build.pre_hook", "build.post_hook"],
    "minBuilderVersion": "1.0.0",
    "license": "MIT"
}

def handle_request(request):
    method = request["method"]
    req_id = request["id"]
    
    if method == "plugin.info":
        return success_response(req_id, PLUGIN_INFO)
    elif method == "build.pre_hook":
        return handle_pre_hook(request)
    elif method == "build.post_hook":
        return handle_post_hook(request)
    else:
        return error_response(-32601, f"Method not found: {method}")

def handle_pre_hook(request):
    # TODO: Implement your pre-build logic here
    return success_response(request["id"], {
        "success": True,
        "logs": ["Pre-build hook executed"]
    })

def handle_post_hook(request):
    # TODO: Implement your post-build logic here
    return success_response(request["id"], {
        "success": True,
        "logs": ["Post-build hook executed"]
    })

def success_response(req_id, result):
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": result
    }

def error_response(code, message):
    return {
        "jsonrpc": "2.0",
        "error": {
            "code": code,
            "message": message
        }
    }

def main():
    for line in sys.stdin:
        try:
            request = json.loads(line)
            response = handle_request(request)
            print(json.dumps(response))
            sys.stdout.flush()
        except Exception as e:
            print(json.dumps(error_response(-32603, str(e))))
            sys.stdout.flush()

if __name__ == "__main__":
    main()
`;
}

private string getGoTemplate(string name) pure @safe {
    return `package main

import (
    "bufio"
    "encoding/json"
    "fmt"
    "os"
)

type PluginInfo struct {
    Name              string   ` ~ "`json:\"name\"`" ~ `
    Version           string   ` ~ "`json:\"version\"`" ~ `
    Author            string   ` ~ "`json:\"author\"`" ~ `
    Description       string   ` ~ "`json:\"description\"`" ~ `
    Homepage          string   ` ~ "`json:\"homepage\"`" ~ `
    Capabilities      []string ` ~ "`json:\"capabilities\"`" ~ `
    MinBuilderVersion string   ` ~ "`json:\"minBuilderVersion\"`" ~ `
    License           string   ` ~ "`json:\"license\"`" ~ `
}

func main() {
    scanner := bufio.NewScanner(os.Stdin)
    for scanner.Scan() {
        var request map[string]interface{}
        if err := json.Unmarshal(scanner.Bytes(), &request); err != nil {
            writeError(-32700, "Parse error")
            continue
        }
        
        response := handleRequest(request)
        json.NewEncoder(os.Stdout).Encode(response)
    }
}

func handleRequest(request map[string]interface{}) map[string]interface{} {
    method := request["method"].(string)
    id := int64(request["id"].(float64))
    
    switch method {
    case "plugin.info":
        return handleInfo(id)
    case "build.pre_hook":
        return handlePreHook(id, request["params"])
    case "build.post_hook":
        return handlePostHook(id, request["params"])
    default:
        return errorResponse(id, -32601, "Method not found")
    }
}

func handleInfo(id int64) map[string]interface{} {
    info := PluginInfo{
        Name:              "` ~ name ~ `",
        Version:           "1.0.0",
        Author:            "Griffin",
        Description:       "` ~ name ~ ` plugin for Builder",
        Homepage:          "https://github.com/GriffinCanCode/builder-plugin-` ~ name ~ `",
        Capabilities:      []string{"build.pre_hook", "build.post_hook"},
        MinBuilderVersion: "1.0.0",
        License:           "MIT",
    }
    
    return successResponse(id, info)
}

func handlePreHook(id int64, params interface{}) map[string]interface{} {
    // TODO: Implement your pre-build logic here
    return successResponse(id, map[string]interface{}{
        "success": true,
        "logs":    []string{"Pre-build hook executed"},
    })
}

func handlePostHook(id int64, params interface{}) map[string]interface{} {
    // TODO: Implement your post-build logic here
    return successResponse(id, map[string]interface{}{
        "success": true,
        "logs":    []string{"Post-build hook executed"},
    })
}

func successResponse(id int64, result interface{}) map[string]interface{} {
    return map[string]interface{}{
        "jsonrpc": "2.0",
        "id":      id,
        "result":  result,
    }
}

func errorResponse(id int64, code int, message string) map[string]interface{} {
    return map[string]interface{}{
        "jsonrpc": "2.0",
        "id":      id,
        "error": map[string]interface{}{
            "code":    code,
            "message": message,
        },
    }
}

func writeError(code int, message string) {
    json.NewEncoder(os.Stderr).Encode(map[string]interface{}{
        "jsonrpc": "2.0",
        "error": map[string]interface{}{
            "code":    code,
            "message": message,
        },
    })
}
`;
}

private string getGoModTemplate(string name) pure @safe {
    return `module github.com/GriffinCanCode/builder-plugin-` ~ name ~ `

go 1.21
`;
}

private string getRustTemplate(string name) pure @safe {
    return `use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{self, BufRead};

#[derive(Serialize)]
struct PluginInfo {
    name: String,
    version: String,
    author: String,
    description: String,
    homepage: String,
    capabilities: Vec<String>,
    #[serde(rename = "minBuilderVersion")]
    min_builder_version: String,
    license: String,
}

fn main() {
    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        match line {
            Ok(line) => {
                match serde_json::from_str::<Value>(&line) {
                    Ok(request) => {
                        let response = handle_request(request);
                        println!("{}", response);
                    }
                    Err(e) => {
                        eprintln!("Parse error: {}", e);
                    }
                }
            }
            Err(e) => {
                eprintln!("Read error: {}", e);
            }
        }
    }
}

fn handle_request(request: Value) -> String {
    let method = request["method"].as_str().unwrap_or("");
    let id = request["id"].as_i64().unwrap_or(0);
    
    let response = match method {
        "plugin.info" => handle_info(id),
        "build.pre_hook" => handle_pre_hook(id, &request["params"]),
        "build.post_hook" => handle_post_hook(id, &request["params"]),
        _ => error_response(id, -32601, "Method not found"),
    };
    
    serde_json::to_string(&response).unwrap()
}

fn handle_info(id: i64) -> Value {
    let info = PluginInfo {
        name: "` ~ name ~ `".to_string(),
        version: "1.0.0".to_string(),
        author: "Griffin".to_string(),
        description: "` ~ name ~ ` plugin for Builder".to_string(),
        homepage: "https://github.com/GriffinCanCode/builder-plugin-` ~ name ~ `".to_string(),
        capabilities: vec!["build.pre_hook".to_string(), "build.post_hook".to_string()],
        min_builder_version: "1.0.0".to_string(),
        license: "MIT".to_string(),
    };
    
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": info
    })
}

fn handle_pre_hook(id: i64, _params: &Value) -> Value {
    // TODO: Implement your pre-build logic here
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "success": true,
            "logs": ["Pre-build hook executed"]
        }
    })
}

fn handle_post_hook(id: i64, _params: &Value) -> Value {
    // TODO: Implement your pre-build logic here
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": {
            "success": true,
            "logs": ["Post-build hook executed"]
        }
    })
}

fn error_response(id: i64, code: i32, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "message": message
        }
    })
}
`;
}

private string getCargoTomlTemplate(string name) pure @safe {
    return `[package]
name = "builder-plugin-` ~ name ~ `"
version = "1.0.0"
edition = "2021"

[[bin]]
name = "builder-plugin-` ~ name ~ `"
path = "src/main.rs"

[dependencies]
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
`;
}

private string getReadmeTemplate(string name, string lang, string buildCmd) pure @safe {
    return `# builder-plugin-` ~ name ~ `

Builder plugin: ` ~ name ~ `

## Build

` ~ "```bash" ~ `
` ~ buildCmd ~ `
` ~ "```" ~ `

## Install

` ~ "```bash" ~ `
cp builder-plugin-` ~ name ~ ` /usr/local/bin/
` ~ "```" ~ `

## Test

` ~ "```bash" ~ `
echo '{"jsonrpc":"2.0","id":1,"method":"plugin.info"}' | ./builder-plugin-` ~ name ~ `
` ~ "```" ~ `

## License

MIT
`;
}

private string getLicenseTemplate() pure @safe {
    return `MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
`;
}

private string getDGitignoreTemplate() pure @safe {
    return `.dub
*.o
*.obj
*.a
*.lib
*.so
*.dylib
*.dll
*.exe
dub.selections.json
builder-plugin-*
`;
}

