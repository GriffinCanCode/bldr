module languages.compiled.protobuf.core.handler;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import std.string : lineSplitter;
import languages.base.base;
import languages.base.mixins;
import languages.compiled.protobuf.core.config;
import languages.compiled.protobuf.tooling.protoc;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;
import engine.graph;

/// Protocol Buffer build handler with action-level caching and dynamic discovery
class ProtobufHandler : BaseLanguageHandler, DiscoverableAction
{
    mixin CachingHandlerMixin!"protobuf";
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        structuredLog.debug_("building_protocol_buffer_target_").field("detail", "Building Protocol Buffer target: " ~ target.name).emit();
        
        // Parse protobuf configuration
        ProtobufConfig pbConfig = parseProtobufConfig(target, config);
        
        // Validate proto files
        if (target.sources.empty)
        {
            result.error = "No proto files specified";
            return result;
        }
        
        // Filter for .proto files only
        string[] protoFiles;
        foreach (source; target.sources)
        {
            if (extension(source) == ".proto")
            {
                protoFiles ~= source;
            }
        }
        
        if (protoFiles.empty)
        {
            result.error = "No .proto files found in sources";
            return result;
        }
        
        // Run linter if requested
        if (pbConfig.lint && BufWrapper.isAvailable())
        {
            structuredLog.debug_("running_buf_lint").emit();
            auto lintResult = BufWrapper.lint(protoFiles);
            if (!lintResult.success)
            {
                structuredLog.warning("linting_issues_found").emit();
                structuredLog.warning("log_event").field("message", lintResult.error).emit();
            }
            else if (!lintResult.warnings.empty)
            {
                foreach (warning; lintResult.warnings)
                {
                    if (!warning.empty)
                        structuredLog.warning("__").field("detail", "  " ~ warning).emit();
                }
            }
        }
        
        // Run formatter if requested
        if (pbConfig.format && BufWrapper.isAvailable())
        {
            structuredLog.debug_("running_buf_format").emit();
            auto fmtResult = BufWrapper.format(protoFiles, true);
            if (!fmtResult.success)
            {
                structuredLog.warning("format_issues_found_").field("detail", "Format issues found: " ~ fmtResult.error).emit();
            }
        }
        
        // Compile proto files
        return compileProtoFiles(protoFiles, pbConfig, config);
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        ProtobufConfig pbConfig = parseProtobufConfig(target, config);
        
        string outputDir = pbConfig.outputDir.empty ? 
                          config.options.outputDir : 
                          pbConfig.outputDir;
        
        // Return the output directory path
        // The actual generated files depend on the proto file content
        return [outputDir];
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        Import[] allImports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            try
            {
                auto content = readText(source);
                auto imports = parseProtoImports(source, content);
                allImports ~= imports;
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_analyze_imports_in_").field("detail", "Failed to analyze imports in " ~ source ~ ": " ~ e.msg).emit();
            }
        }
        
        return allImports;
    }
    
    /// Execute with discovery to find generated files
    DiscoveryResult executeWithDiscovery(Target target, WorkspaceConfig config) @system
    {
        DiscoveryResult result;
        result.success = false;
        result.hasDiscovery = false;
        
        structuredLog.info("executing_protobuf_discovery_for_").field("detail", "Executing protobuf discovery for " ~ target.name).emit();
        
        // Parse configuration
        ProtobufConfig pbConfig = parseProtobufConfig(target, config);
        
        // Filter proto files
        string[] protoFiles;
        foreach (source; target.sources)
        {
            if (extension(source) == ".proto")
                protoFiles ~= source;
        }
        
        if (protoFiles.empty)
        {
            result.error = "No .proto files found";
            return result;
        }
        
        // Compile to generate output files
        auto buildResult = compileProtoFiles(protoFiles, pbConfig, config);
        if (!buildResult.success)
        {
            result.error = buildResult.error;
            return result;
        }
        
        result.success = true;
        
        // Discover generated files
        string[] discoveredFiles = buildResult.outputs;
        if (discoveredFiles.empty)
        {
            // No files generated (shouldn't happen), no discovery
            return result;
        }
        
        // Create discovery metadata
        result.hasDiscovery = true;
        
        auto builder = DiscoveryBuilder.forTarget(target.id);
        builder = builder.addOutputs(discoveredFiles);
        builder = builder.withMetadata("generator", "protobuf");
        builder = builder.withMetadata("output_language", pbConfig.outputLanguage.to!string);
        
        // Create compile targets for generated files by language
        Target[] compileTargets;
        TargetId[] compileIds;
        
        // Group files by extension
        string[][string] filesByExt;
        foreach (file; discoveredFiles)
        {
            auto ext = extension(file);
            if (ext !in filesByExt)
                filesByExt[ext] = [];
            filesByExt[ext] ~= file;
        }
        
        // Create targets for each language
        foreach (ext, files; filesByExt)
        {
            auto targetName = target.name ~ "-generated" ~ ext.replace(".", "-");
            auto compileTarget = createCompileTarget(targetName, files, target.id, pbConfig);
            if (compileTarget.language != TargetLanguage.Generic)
            {
                compileTargets ~= compileTarget;
                compileIds ~= TargetId(targetName);
            }
        }
        
        if (!compileTargets.empty)
        {
            builder = builder.addTargets(compileTargets);
            builder = builder.addDependents(compileIds);
            
            structuredLog.info("discovered_").field("detail", "Discovered " ~ compileTargets.length.to!string ~ 
                         " compile targets from protobuf generation").emit();
        }
        
        result.discovery = builder.build();
        return result;
    }
    
    /// Create a compile target for generated files
    private Target createCompileTarget(
        string name,
        string[] sources,
        TargetId protoTargetId,
        ProtobufConfig pbConfig
    ) @system
    {
        Target target;
        target.name = name;
        target.sources = sources;
        target.deps = [protoTargetId.toString()];
        target.type = TargetType.Library;
        
        // Infer language from protobuf output language setting
        switch (pbConfig.outputLanguage)
        {
            case ProtobufOutputLanguage.Cpp:
                target.language = TargetLanguage.Cpp;
                break;
            case ProtobufOutputLanguage.CSharp:
                target.language = TargetLanguage.CSharp;
                break;
            case ProtobufOutputLanguage.Java:
                target.language = TargetLanguage.Java;
                break;
            case ProtobufOutputLanguage.Python:
                target.language = TargetLanguage.Python;
                break;
            case ProtobufOutputLanguage.Go:
                target.language = TargetLanguage.Go;
                break;
            case ProtobufOutputLanguage.Rust:
                target.language = TargetLanguage.Rust;
                break;
            case ProtobufOutputLanguage.JavaScript:
                target.language = TargetLanguage.JavaScript;
                break;
            case ProtobufOutputLanguage.TypeScript:
                target.language = TargetLanguage.TypeScript;
                break;
            default:
                target.language = TargetLanguage.Generic;
                break;
        }
        
        return target;
    }
    
    private LanguageBuildResult compileProtoFiles(
        const string[] protoFiles,
        const ProtobufConfig pbConfig,
        const WorkspaceConfig config
    )
    {
        LanguageBuildResult result;
        
        // Select compiler
        bool useProtoc = true;
        
        if (pbConfig.compiler == ProtocCompiler.Buf)
        {
            if (BufWrapper.isAvailable())
            {
                useProtoc = false;
            }
            else
            {
                structuredLog.warning("buf_compiler_not_available_falling_back_").emit();
            }
        }
        
        // For now, we only support protoc (buf generate would need different implementation)
        if (!ProtocWrapper.isAvailable())
        {
            result.error = "protoc compiler not found. Install from: https://protobuf.dev/downloads/";
            return result;
        }
        
        structuredLog.debug_("using_protoc_").field("detail", "Using protoc: " ~ ProtocWrapper.getVersion()).emit();
        
        // Compile with action-level caching
        auto compileResult = ProtocWrapper.compile(
            protoFiles, 
            pbConfig, 
            config.root,
            actionCache,
            "protobuf"
        );
        
        if (!compileResult.success)
        {
            result.error = compileResult.error;
            return result;
        }
        
        // Report warnings
        if (!compileResult.warnings.empty)
        {
            structuredLog.warning("compilation_warnings").emit();
            foreach (warn; compileResult.warnings)
            {
                structuredLog.warning("__").field("detail", "  " ~ warn).emit();
            }
        }
        
        result.success = true;
        result.outputs = compileResult.outputs;
        
        // Generate output hash from generated files
        if (!result.outputs.empty)
        {
            result.outputHash = FastHash.hashString(result.outputs.join("\n"));
        }
        
        return result;
    }
    
    private ProtobufConfig parseProtobufConfig(in Target target, in WorkspaceConfig workspace)
    {
        ProtobufConfig config;
        
        // Try language-specific keys
        string configKey = "";
        if ("protobuf" in target.langConfig)
            configKey = "protobuf";
        else if ("proto" in target.langConfig)
            configKey = "proto";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = ProtobufConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_protobuf_config_using_de").field("detail", "Failed to parse Protobuf config, using defaults: " ~ e.msg).emit();
            }
        }
        
        // Set default output directory if not specified
        if (config.outputDir.empty)
        {
            config.outputDir = workspace.options.outputDir;
        }
        
        return config;
    }
    
    /// Parse proto imports from file content
    private Import[] parseProtoImports(string filepath, string content)
    {
        Import[] imports;
        
        import std.regex;
        import std.string : strip;
        
        // Match: import "path/to/file.proto";
        // Or: import public "path/to/file.proto";
        // Or: import weak "path/to/file.proto";
        auto importRegex = regex(`import\s+(?:public\s+|weak\s+)?"([^"]+)"`, "g");
        
        size_t lineNum = 1;
        foreach (line; content.lineSplitter)
        {
            auto matches = matchAll(line, importRegex);
            foreach (match; matches)
            {
                if (match.length >= 2)
                {
                    Import imp;
                    imp.moduleName = match[1];
                    imp.kind = determineImportKind(match[1]);
                    imp.location = SourceLocation(filepath, lineNum, 0);
                    imports ~= imp;
                }
            }
            lineNum++;
        }
        
        return imports;
    }
    
    /// Determine import kind for proto files
    private ImportKind determineImportKind(string importPath)
    {
        // Well-known types from google/protobuf are external
        if (importPath.startsWith("google/protobuf/"))
            return ImportKind.External;
        
        // Absolute paths
        if (isAbsolute(importPath))
            return ImportKind.Absolute;
        
        // Relative paths (most common in proto files)
        return ImportKind.Relative;
    }
}

