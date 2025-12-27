module languages.compiled.protobuf.core.handler;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import std.string : lineSplitter, replace;
import std.regex;
import languages.compiled.base;
import languages.compiled.protobuf.core.config;
import languages.compiled.protobuf.tooling.protoc;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.graph;

/// Protocol Buffer build handler with protoc and buf support
class ProtobufHandler : BaseCompiledLanguageHandler, DiscoverableAction
{
    private ProtobufConfig _config;
    
    this() { super(null); }
    
    // ===== Required Overrides =====
    
    override protected string languageId() const pure nothrow => "protobuf";
    
    override protected TargetLanguage languageType() const pure nothrow => TargetLanguage.Protobuf;
    
    override protected string[] configKeys() const pure nothrow => ["protobuf", "proto"];
    
    override protected string toolchainNotFoundError() const pure nothrow =>
        "Protocol Buffer compiler not found. Install protoc from: https://github.com/protocolbuffers/protobuf/releases";
    
    override protected string detectToolchain(in Target target, in WorkspaceConfig config) @system
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        
        parseProtobufConfig(target, config);
        
        if (ProtocWrapper.isAvailable()) return ExecutableDetector.findInPath("protoc");
        if (BufWrapper.isAvailable()) return ExecutableDetector.findInPath("buf");
        return "";
    }
    
    /// Get toolchain version string
    string getToolchainVersion() @system
    {
        if (ProtocWrapper.isAvailable()) return "protoc " ~ ProtocWrapper.getVersion();
        if (BufWrapper.isAvailable()) return "buf (available)";
        return "unknown";
    }
    
    private void parseProtobufConfig(in Target target, in WorkspaceConfig config) @system
    {
        _config = ProtobufConfig.init;
        
        string configKey = "protobuf" in target.langConfig ? "protobuf" :
                          ("proto" in target.langConfig ? "proto" : "");
        
        if (!configKey.empty)
        {
            try { _config = ProtobufConfig.fromJSON(parseJSON(target.langConfig[configKey])); }
            catch (Exception e) { structuredLog.warning("failed_to_parse_protobuf_config").field("error", e.msg).emit(); }
        }
        
        if (_config.outputDir.empty)
            _config.outputDir = config.options.outputDir;
    }
    
    override protected bool shouldFormat(in Target target) const @system => _config.format;
    
    override protected bool shouldLint(in Target target) const @system => _config.lint;
    
    override protected CompiledLanguageResult runFormatter(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        result.success = true;
        
        if (!_config.format || !BufWrapper.isAvailable())
            return result;
        
        structuredLog.debug_("running_buf_format").emit();
        auto protoFiles = target.sources.filter!(s => extension(s) == ".proto").array;
        
        auto fmtResult = BufWrapper.format(protoFiles, true);
        result.success = fmtResult.success;
        if (!fmtResult.success)
            result.warnings ~= fmtResult.error;
        
        return result;
    }
    
    override protected CompiledLanguageResult runLinter(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        result.success = true;
        
        if (!_config.lint || !BufWrapper.isAvailable())
            return result;
        
        structuredLog.debug_("running_buf_lint").emit();
        auto protoFiles = target.sources.filter!(s => extension(s) == ".proto").array;
        
        auto lintResult = BufWrapper.lint(protoFiles);
        result.success = lintResult.success;
        result.hadLintIssues = !lintResult.warnings.empty;
        result.lintIssues = lintResult.warnings.dup;
        
        return result;
    }
    
    override protected LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        return doCompile(target, config);
    }
    
    override protected LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        return doCompile(target, config);
    }
    
    override protected LanguageBuildResult buildAndRunTests(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        return doCompile(target, config);
    }
    
    private LanguageBuildResult doCompile(in Target target, in WorkspaceConfig config) @system
    {
        LanguageBuildResult result;
        
        // Filter for .proto files
        auto protoFiles = target.sources.filter!(s => extension(s) == ".proto").array;
        
        if (protoFiles.empty)
        {
            result.error = "No .proto files found in sources";
            return result;
        }
        
        // Select compiler
        bool useProtoc = true;
        if (_config.compiler == ProtocCompiler.Buf && BufWrapper.isAvailable())
            useProtoc = false;
        else if (!ProtocWrapper.isAvailable())
        {
            result.error = "protoc compiler not found. Install from: https://protobuf.dev/downloads/";
            return result;
        }
        
        structuredLog.debug_("using_protoc").field("version", ProtocWrapper.getVersion()).emit();
        
        // Compile with action-level caching
        auto compileResult = ProtocWrapper.compile(
            protoFiles,
            _config,
            config.root,
            actionCache,
            "protobuf"
        );
        
        result.success = compileResult.success;
        result.error = compileResult.error;
        result.outputs = compileResult.outputs.dup;
        
        if (!result.outputs.empty)
            result.outputHash = FastHash.hashString(result.outputs.join("\n"));
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config) @system
    {
        string outputDir = _config.outputDir.empty ? config.options.outputDir : _config.outputDir;
        return [outputDir];
    }
    
    override Import[] analyzeImports(in string[] sources) @system
    {
        Import[] imports;
        
        auto importRegex = regex(`import\s+(?:public\s+|weak\s+)?"([^"]+)"`, "g");
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source)) continue;
            
            try
            {
                auto content = readText(source);
                size_t lineNum = 1;
                
                foreach (line; content.lineSplitter)
                {
                    foreach (match; line.matchAll(importRegex))
                    {
                        if (match.length >= 2)
                        {
                            Import imp;
                            imp.moduleName = match[1];
                            imp.kind = determineImportKind(match[1]);
                            imp.location = SourceLocation(source, lineNum, 0);
                            imports ~= imp;
                        }
                    }
                    lineNum++;
                }
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_analyze_imports").field("file", source).field("error", e.msg).emit();
            }
        }
        
        return imports;
    }
    
    // ===== DiscoverableAction Interface =====
    
    DiscoveryResult executeWithDiscovery(Target target, WorkspaceConfig config) @system
    {
        DiscoveryResult result;
        result.success = false;
        result.hasDiscovery = false;
        
        structuredLog.info("executing_protobuf_discovery").field("target", target.name).emit();
        
        // Parse configuration
        parseProtobufConfig(target, config);
        
        // Filter proto files
        auto protoFiles = target.sources.filter!(s => extension(s) == ".proto").array;
        
        if (protoFiles.empty)
        {
            result.error = "No .proto files found";
            return result;
        }
        
        // Compile to generate output files
        auto buildResult = doCompile(target, config);
        if (!buildResult.success)
        {
            result.error = buildResult.error;
            return result;
        }
        
        result.success = true;
        
        if (buildResult.outputs.empty)
            return result;
        
        // Create discovery metadata
        result.hasDiscovery = true;
        
        auto builder = DiscoveryBuilder.forTarget(target.id);
        builder = builder.addOutputs(buildResult.outputs);
        builder = builder.withMetadata("generator", "protobuf");
        builder = builder.withMetadata("output_language", _config.outputLanguage.to!string);
        
        // Group files by extension and create compile targets
        string[][string] filesByExt;
        foreach (file; buildResult.outputs)
        {
            auto ext = extension(file);
            if (ext !in filesByExt) filesByExt[ext] = [];
            filesByExt[ext] ~= file;
        }
        
        Target[] compileTargets;
        TargetId[] compileIds;
        
        foreach (ext, files; filesByExt)
        {
            auto targetName = target.name ~ "-generated" ~ ext.replace(".", "-");
            auto compileTarget = createCompileTarget(targetName, files, target.id);
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
            structuredLog.info("discovered_compile_targets").field("count", compileTargets.length).emit();
        }
        
        result.discovery = builder.build();
        return result;
    }
    
    // ===== Private Helpers =====
    
    private Target createCompileTarget(string name, string[] sources, TargetId protoTargetId) @system
    {
        Target target;
        target.name = name;
        target.sources = sources;
        target.deps = [protoTargetId.toString()];
        target.type = TargetType.Library;
        
        switch (_config.outputLanguage)
        {
            case ProtobufOutputLanguage.Cpp: target.language = TargetLanguage.Cpp; break;
            case ProtobufOutputLanguage.CSharp: target.language = TargetLanguage.CSharp; break;
            case ProtobufOutputLanguage.Java: target.language = TargetLanguage.Java; break;
            case ProtobufOutputLanguage.Python: target.language = TargetLanguage.Python; break;
            case ProtobufOutputLanguage.Go: target.language = TargetLanguage.Go; break;
            case ProtobufOutputLanguage.Rust: target.language = TargetLanguage.Rust; break;
            case ProtobufOutputLanguage.JavaScript: target.language = TargetLanguage.JavaScript; break;
            case ProtobufOutputLanguage.TypeScript: target.language = TargetLanguage.TypeScript; break;
            default: target.language = TargetLanguage.Generic; break;
        }
        
        return target;
    }
    
    private ImportKind determineImportKind(string importPath)
    {
        if (importPath.startsWith("google/protobuf/"))
            return ImportKind.External;
        if (isAbsolute(importPath))
            return ImportKind.Absolute;
        return ImportKind.Relative;
    }
}
