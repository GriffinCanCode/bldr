module languages.web.typescript.tooling.checker;

import std.process : execute, Config;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import std.conv;
import languages.web.typescript.tooling.bundlers.base;
import infrastructure.utils.logging;

/// Type checking result
struct TypeCheckResult
{
    bool success;
    string[] errors;
    string[] warnings;
    bool hasErrors() const => !errors.empty;
    bool hasWarnings() const => !warnings.empty;
}

/// TypeScript type checker - performs type checking without compilation
class TypeChecker
{
    /// Type check TypeScript files using tsc --noEmit
    static TypeCheckResult check(const(string[]) sources, TSConfig config, string workspaceRoot)
    {
        TypeCheckResult result;
        
        if (!isTSCAvailable())
        {
            result.errors ~= "TypeScript compiler (tsc) not found. Install: npm install -g typescript";
            return result;
        }
        
        string[] cmd = ["tsc", "--noEmit"];
        
        if (!config.tsconfig.empty && exists(config.tsconfig))
            cmd ~= ["--project", config.tsconfig];
        else
        {
            cmd ~= buildInlineConfig(config);
            cmd ~= sources;
        }
        
        structuredLog.debug_("type_checking").field("detail", cmd.join(" ")).emit();
        auto res = execute(cmd, null, Config.none, size_t.max, workspaceRoot);
        
        if (res.status == 0)
        {
            result.success = true;
            structuredLog.debug_("type_checking_passed").emit();
        }
        else
        {
            result.success = false;
            parseTypeScriptOutput(res.output, result);
            structuredLog.debug_("type_checking_failed").field("detail", result.errors.length.to!string ~ " errors").emit();
        }
        
        return result;
    }
    
    static bool isTSCAvailable() { return execute(["tsc", "--version"]).status == 0; }
    
    static string getTSCVersion()
    {
        auto res = execute(["tsc", "--version"]);
        return res.status == 0 ? res.output.strip : "unknown";
    }
    
    static TypeCheckResult validateTSConfig(string tsconfigPath)
    {
        TypeCheckResult result;
        if (!exists(tsconfigPath))
        {
            result.errors ~= "tsconfig.json not found: " ~ tsconfigPath;
            return result;
        }
        try
        {
            auto json = parseJSON(readText(tsconfigPath));
            if ("compilerOptions" !in json)
                result.warnings ~= "tsconfig.json missing 'compilerOptions'";
            result.success = true;
        }
        catch (Exception e)
        {
            result.errors ~= "Invalid tsconfig.json: " ~ e.msg;
        }
        return result;
    }
    
    static TSConfig loadFromTSConfig(string tsconfigPath)
    {
        TSConfig config;
        if (!exists(tsconfigPath))
        {
            structuredLog.warning("tsconfig_not_found").field("detail", tsconfigPath).emit();
            return config;
        }
        
        try
        {
            auto json = parseJSON(readText(tsconfigPath));
            if ("compilerOptions" in json)
            {
                auto opts = json["compilerOptions"].object;
                
                if ("target" in opts && opts["target"].type == JSONType.string)
                {
                    string s = opts["target"].str.toLower;
                    if (s == "es5") config.target = TSTarget.ES5;
                    else if (s == "es6" || s == "es2015") config.target = TSTarget.ES2015;
                    else if (s == "es2020") config.target = TSTarget.ES2020;
                    else if (s == "esnext") config.target = TSTarget.ESNext;
                }
                
                if ("module" in opts && opts["module"].type == JSONType.string)
                {
                    string s = opts["module"].str.toLower;
                    if (s == "commonjs") config.moduleFormat = TSModuleFormat.CommonJS;
                    else if (s == "esm" || s == "es6" || s == "es2015") config.moduleFormat = TSModuleFormat.ESM;
                    else if (s == "es2020") config.moduleFormat = TSModuleFormat.ES2020;
                    else if (s == "esnext") config.moduleFormat = TSModuleFormat.ESNext;
                }
                
                if ("strict" in opts) config.strict = opts["strict"].type == JSONType.true_;
                if ("declaration" in opts) config.declaration = opts["declaration"].type == JSONType.true_;
                if ("sourceMap" in opts) config.sourceMap = opts["sourceMap"].type == JSONType.true_;
                if ("skipLibCheck" in opts) config.skipLibCheck = opts["skipLibCheck"].type == JSONType.true_;
                if ("esModuleInterop" in opts) config.esModuleInterop = opts["esModuleInterop"].type == JSONType.true_;
                if ("outDir" in opts && opts["outDir"].type == JSONType.string)
                    config.outDir = opts["outDir"].str;
                if ("rootDir" in opts && opts["rootDir"].type == JSONType.string)
                    config.rootDir = opts["rootDir"].str;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("tsconfig_parse_failed").field("detail", e.msg).emit();
        }
        
        return config;
    }
    
    private static string[] buildInlineConfig(TSConfig config)
    {
        string[] args;
        args ~= ["--target", targetToString(config.target)];
        args ~= ["--module", moduleToString(config.moduleFormat)];
        args ~= ["--moduleResolution", moduleResolutionToString(config.moduleResolution)];
        
        if (config.strict) args ~= "--strict";
        if (config.skipLibCheck) args ~= "--skipLibCheck";
        if (config.allowJs) args ~= "--allowJs";
        if (config.esModuleInterop) args ~= "--esModuleInterop";
        if (config.isolatedModules) args ~= "--isolatedModules";
        if (config.experimentalDecorators) args ~= "--experimentalDecorators";
        if (config.emitDecoratorMetadata) args ~= "--emitDecoratorMetadata";
        
        if (config.jsx != TSXMode.React)
            args ~= ["--jsx", jsxModeToString(config.jsx)];
        
        return args;
    }
    
    private static void parseTypeScriptOutput(string output, ref TypeCheckResult result)
    {
        foreach (line; output.split("\n"))
        {
            auto trimmed = line.strip;
            if (trimmed.empty) continue;
            if (trimmed.indexOf("error TS") != -1)
                result.errors ~= trimmed;
            else if (trimmed.indexOf("warning TS") != -1)
                result.warnings ~= trimmed;
        }
    }
    
    private static string targetToString(TSTarget t)
    {
        final switch (t)
        {
            case TSTarget.ES3: return "ES3";
            case TSTarget.ES5: return "ES5";
            case TSTarget.ES6, TSTarget.ES2015: return "ES2015";
            case TSTarget.ES2016: return "ES2016";
            case TSTarget.ES2017: return "ES2017";
            case TSTarget.ES2018: return "ES2018";
            case TSTarget.ES2019: return "ES2019";
            case TSTarget.ES2020: return "ES2020";
            case TSTarget.ES2021: return "ES2021";
            case TSTarget.ES2022: return "ES2022";
            case TSTarget.ES2023: return "ES2023";
            case TSTarget.ESNext: return "ESNext";
        }
    }
    
    private static string moduleToString(TSModuleFormat m)
    {
        final switch (m)
        {
            case TSModuleFormat.CommonJS: return "CommonJS";
            case TSModuleFormat.ESM, TSModuleFormat.ES2015: return "ES2015";
            case TSModuleFormat.UMD: return "UMD";
            case TSModuleFormat.AMD: return "AMD";
            case TSModuleFormat.System: return "System";
            case TSModuleFormat.ES2020: return "ES2020";
            case TSModuleFormat.ESNext: return "ESNext";
            case TSModuleFormat.Node16: return "Node16";
            case TSModuleFormat.NodeNext: return "NodeNext";
        }
    }
    
    private static string moduleResolutionToString(TSModuleResolution r)
    {
        final switch (r)
        {
            case TSModuleResolution.Classic: return "Classic";
            case TSModuleResolution.Node: return "Node";
            case TSModuleResolution.Node16: return "Node16";
            case TSModuleResolution.NodeNext: return "NodeNext";
            case TSModuleResolution.Bundler: return "Bundler";
        }
    }
    
    private static string jsxModeToString(TSXMode m)
    {
        final switch (m)
        {
            case TSXMode.Preserve: return "preserve";
            case TSXMode.React: return "react";
            case TSXMode.ReactJSX: return "react-jsx";
            case TSXMode.ReactJSXDev: return "react-jsxdev";
            case TSXMode.ReactNative: return "react-native";
        }
    }
}
