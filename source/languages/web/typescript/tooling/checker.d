module languages.web.typescript.tooling.checker;

import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import std.conv;
import languages.web.typescript.core.config;
import infrastructure.utils.logging;

/// Type checking result
struct TypeCheckResult
{
    bool success;
    string[] errors;
    string[] warnings;
    
    /// Check if there are any errors
    bool hasErrors() const
    {
        return !errors.empty;
    }
    
    /// Check if there are any warnings
    bool hasWarnings() const
    {
        return !warnings.empty;
    }
}

/// TypeScript type checker - performs type checking without compilation
class TypeChecker
{
    /// Type check TypeScript files using tsc --noEmit
    static TypeCheckResult check(const(string[]) sources, TSConfig config, string workspaceRoot)
    {
        TypeCheckResult result;
        
        // Check if tsc is available
        if (!isTSCAvailable())
        {
            result.errors ~= "TypeScript compiler (tsc) not found. Install: npm install -g typescript";
            return result;
        }
        
        // Build tsc command for type checking only
        string[] cmd = ["tsc", "--noEmit"];
        
        // Add tsconfig if specified
        if (!config.tsconfig.empty && exists(config.tsconfig))
        {
            cmd ~= ["--project", config.tsconfig];
        }
        else
        {
            // Build inline config
            cmd ~= buildInlineConfig(config);
            
            // Add source files
            cmd ~= sources;
        }
        
        structuredLog.debug_("type_checking_").field("detail", "Type checking: " ~ cmd.join(" ")).emit();
        
        // Execute tsc
        auto res = execute(cmd, null, Config.none, size_t.max, workspaceRoot);
        
        if (res.status == 0)
        {
            result.success = true;
            structuredLog.debug_("type_checking_passed").emit();
        }
        else
        {
            result.success = false;
            // Parse TypeScript error output
            parseTypeScriptOutput(res.output, result);
            structuredLog.debug_("type_checking_failed_with_").field("detail", "Type checking failed with " ~ result.errors.length.to!string ~ " errors").emit();
        }
        
        return result;
    }
    
    /// Check if TypeScript compiler is available
    static bool isTSCAvailable()
    {
        auto res = execute(["tsc", "--version"]);
        return res.status == 0;
    }
    
    /// Get TypeScript compiler version
    static string getTSCVersion()
    {
        auto res = execute(["tsc", "--version"]);
        if (res.status == 0)
            return res.output.strip;
        return "unknown";
    }
    
    /// Validate tsconfig.json file
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
            auto content = readText(tsconfigPath);
            auto json = parseJSON(content);
            
            // Basic validation
            if ("compilerOptions" !in json)
            {
                result.warnings ~= "tsconfig.json missing 'compilerOptions'";
            }
            
            result.success = true;
        }
        catch (Exception e)
        {
            result.errors ~= "Invalid tsconfig.json: " ~ e.msg;
        }
        
        return result;
    }
    
    /// Load TSConfig from tsconfig.json
    static TSConfig loadFromTSConfig(string tsconfigPath)
    {
        TSConfig config;
        
        if (!exists(tsconfigPath))
        {
            structuredLog.warning("tsconfigjson_not_found_").field("detail", "tsconfig.json not found: " ~ tsconfigPath).emit();
            return config;
        }
        
        try
        {
            auto content = readText(tsconfigPath);
            auto json = parseJSON(content);
            
            if ("compilerOptions" in json)
            {
                auto opts = json["compilerOptions"].object;
                
                // Map common options
                if ("target" in opts && opts["target"].type == JSONType.string)
                {
                    string targetStr = opts["target"].str;
                    switch (targetStr.toLower)
                    {
                        case "es3": config.target = TSTarget.ES3; break;
                        case "es5": config.target = TSTarget.ES5; break;
                        case "es6": case "es2015": config.target = TSTarget.ES2015; break;
                        case "es2016": config.target = TSTarget.ES2016; break;
                        case "es2017": config.target = TSTarget.ES2017; break;
                        case "es2018": config.target = TSTarget.ES2018; break;
                        case "es2019": config.target = TSTarget.ES2019; break;
                        case "es2020": config.target = TSTarget.ES2020; break;
                        case "es2021": config.target = TSTarget.ES2021; break;
                        case "es2022": config.target = TSTarget.ES2022; break;
                        case "es2023": config.target = TSTarget.ES2023; break;
                        case "esnext": config.target = TSTarget.ESNext; break;
                        default: break;
                    }
                }
                
                if ("module" in opts && opts["module"].type == JSONType.string)
                {
                    string moduleStr = opts["module"].str;
                    switch (moduleStr.toLower)
                    {
                        case "commonjs": config.moduleFormat = TSModuleFormat.CommonJS; break;
                        case "esm": case "es6": case "es2015": config.moduleFormat = TSModuleFormat.ESM; break;
                        case "umd": config.moduleFormat = TSModuleFormat.UMD; break;
                        case "amd": config.moduleFormat = TSModuleFormat.AMD; break;
                        case "system": config.moduleFormat = TSModuleFormat.System; break;
                        case "es2020": config.moduleFormat = TSModuleFormat.ES2020; break;
                        case "esnext": config.moduleFormat = TSModuleFormat.ESNext; break;
                        case "node16": config.moduleFormat = TSModuleFormat.Node16; break;
                        case "nodenext": config.moduleFormat = TSModuleFormat.NodeNext; break;
                        default: break;
                    }
                }
                
                // Boolean options
                if ("strict" in opts) config.strict = opts["strict"].type == JSONType.true_;
                if ("declaration" in opts) config.declaration = opts["declaration"].type == JSONType.true_;
                if ("sourceMap" in opts) config.sourceMap = opts["sourceMap"].type == JSONType.true_;
                if ("skipLibCheck" in opts) config.skipLibCheck = opts["skipLibCheck"].type == JSONType.true_;
                if ("esModuleInterop" in opts) config.esModuleInterop = opts["esModuleInterop"].type == JSONType.true_;
                
                // String options
                if ("outDir" in opts && opts["outDir"].type == JSONType.string)
                    config.outDir = opts["outDir"].str;
                if ("rootDir" in opts && opts["rootDir"].type == JSONType.string)
                    config.rootDir = opts["rootDir"].str;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_parse_tsconfigjson_").field("detail", "Failed to parse tsconfig.json: " ~ e.msg).emit();
        }
        
        return config;
    }
    
    private static string[] buildInlineConfig(TSConfig config)
    {
        string[] args;
        
        // Target
        args ~= "--target";
        args ~= targetToString(config.target);
        
        // Module
        args ~= "--module";
        args ~= moduleToString(config.moduleFormat);
        
        // Module resolution
        args ~= "--moduleResolution";
        args ~= moduleResolutionToString(config.moduleResolution);
        
        // Boolean flags
        if (config.strict) args ~= "--strict";
        if (config.strictNullChecks) args ~= "--strictNullChecks";
        if (config.strictFunctionTypes) args ~= "--strictFunctionTypes";
        if (config.strictBindCallApply) args ~= "--strictBindCallApply";
        if (config.strictPropertyInitialization) args ~= "--strictPropertyInitialization";
        if (config.noImplicitAny) args ~= "--noImplicitAny";
        if (config.noImplicitThis) args ~= "--noImplicitThis";
        if (config.noImplicitReturns) args ~= "--noImplicitReturns";
        if (config.noFallthroughCasesInSwitch) args ~= "--noFallthroughCasesInSwitch";
        if (config.noUnusedLocals) args ~= "--noUnusedLocals";
        if (config.noUnusedParameters) args ~= "--noUnusedParameters";
        if (config.skipLibCheck) args ~= "--skipLibCheck";
        if (config.allowJs) args ~= "--allowJs";
        if (config.checkJs) args ~= "--checkJs";
        if (config.esModuleInterop) args ~= "--esModuleInterop";
        if (config.allowSyntheticDefaultImports) args ~= "--allowSyntheticDefaultImports";
        if (config.forceConsistentCasingInFileNames) args ~= "--forceConsistentCasingInFileNames";
        if (config.resolveJsonModule) args ~= "--resolveJsonModule";
        if (config.isolatedModules) args ~= "--isolatedModules";
        if (config.preserveConstEnums) args ~= "--preserveConstEnums";
        if (config.removeComments) args ~= "--removeComments";
        if (config.importHelpers) args ~= "--importHelpers";
        if (config.downlevelIteration) args ~= "--downlevelIteration";
        if (config.emitDecoratorMetadata) args ~= "--emitDecoratorMetadata";
        if (config.experimentalDecorators) args ~= "--experimentalDecorators";
        
        // JSX
        if (config.jsx != TSXMode.React)
        {
            args ~= "--jsx";
            args ~= jsxModeToString(config.jsx);
        }
        
        return args;
    }
    
    private static void parseTypeScriptOutput(string output, ref TypeCheckResult result)
    {
        import std.string : split, strip, indexOf;
        
        auto lines = output.split("\n");
        
        foreach (line; lines)
        {
            auto trimmed = line.strip;
            if (trimmed.empty)
                continue;
            
            // TypeScript errors contain: filename(line,col): error TS####: message
            if (trimmed.indexOf("error TS") != -1)
            {
                result.errors ~= trimmed;
            }
            else if (trimmed.indexOf("warning TS") != -1)
            {
                result.warnings ~= trimmed;
            }
        }
    }
    
    private static string targetToString(TSTarget target)
    {
        final switch (target)
        {
            case TSTarget.ES3: return "ES3";
            case TSTarget.ES5: return "ES5";
            case TSTarget.ES6: case TSTarget.ES2015: return "ES2015";
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
    
    private static string moduleToString(TSModuleFormat moduleFormat)
    {
        final switch (moduleFormat)
        {
            case TSModuleFormat.CommonJS: return "CommonJS";
            case TSModuleFormat.ESM: return "ES2015";
            case TSModuleFormat.UMD: return "UMD";
            case TSModuleFormat.AMD: return "AMD";
            case TSModuleFormat.System: return "System";
            case TSModuleFormat.ES2015: return "ES2015";
            case TSModuleFormat.ES2020: return "ES2020";
            case TSModuleFormat.ESNext: return "ESNext";
            case TSModuleFormat.Node16: return "Node16";
            case TSModuleFormat.NodeNext: return "NodeNext";
        }
    }
    
    private static string moduleResolutionToString(TSModuleResolution resolution)
    {
        final switch (resolution)
        {
            case TSModuleResolution.Classic: return "Classic";
            case TSModuleResolution.Node: return "Node";
            case TSModuleResolution.Node16: return "Node16";
            case TSModuleResolution.NodeNext: return "NodeNext";
            case TSModuleResolution.Bundler: return "Bundler";
        }
    }
    
    private static string jsxModeToString(TSXMode mode)
    {
        final switch (mode)
        {
            case TSXMode.Preserve: return "preserve";
            case TSXMode.React: return "react";
            case TSXMode.ReactJSX: return "react-jsx";
            case TSXMode.ReactJSXDev: return "react-jsxdev";
            case TSXMode.ReactNative: return "react-native";
        }
    }
}

