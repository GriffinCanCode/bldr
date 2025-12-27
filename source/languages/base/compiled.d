module languages.base.compiled;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.conv;
import std.string;
import std.regex;
import std.process : environment;
import languages.base.base;
import languages.base.types;
import languages.base.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types : Import, ImportKind, SourceLocation;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;
import engine.caching.actions.action;

/// Base handler for compiled languages (C++, Rust, D, Swift, Zig, CUDA, etc.)
/// Provides common functionality for compile→link workflow
abstract class BaseCompiledHandler : BaseLanguageHandler
{
    protected ActionCache _actionCache;
    
    /// Initialize with optional action cache
    this(ActionCache cache = null) { _actionCache = cache; }
    
    /// Get or create action cache
    protected ActionCache actionCache() @system
    {
        if (_actionCache is null)
        {
            version(unittest)
            {
                import engine.caching.actions.action : NullActionCache;
                _actionCache = new NullActionCache();
            }
            else
            {
                auto cacheConfig = ActionCacheConfig.fromEnvironment();
                _actionCache = new ActionCache(".builder-cache/actions/" ~ languageId(), cacheConfig);
            }
        }
        return _actionCache;
    }
    
    /// Language identifier for cache paths
    protected abstract string languageId() const;
    
    /// Detect compiler/toolkit path
    protected string detectTool(string[] paths, string envVar, string defaultCmd) @system
    {
        // Check environment variable first
        auto envPath = environment.get(envVar, "");
        if (!envPath.empty)
        {
            auto toolPath = buildPath(envPath, "bin", defaultCmd);
            if (exists(toolPath)) return toolPath;
            if (exists(envPath)) return envPath;  // Maybe envVar points directly to tool
        }
        
        // Check provided paths
        foreach (path; paths)
        {
            if (exists(path)) return path;
        }
        
        // Try PATH
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        return ExecutableDetector.findInPath(defaultCmd);
    }
    
    /// Build compiler flags from compiled config
    protected string[] buildCompilerFlags(CompiledConfig config, bool isCpp = true) pure nothrow
    {
        string[] flags;
        
        // Optimization
        flags ~= config.optLevel.toFlag();
        
        // Warnings
        flags ~= config.warnings.toFlags();
        
        // Debug info
        if (config.base.debugInfo) flags ~= "-g";
        
        // PIC/PIE
        if (config.pic || config.outputType == OutputType.SharedLib) flags ~= "-fPIC";
        if (config.pie && config.outputType == OutputType.Executable) flags ~= "-fPIE";
        
        // LTO
        if (config.lto != LtoMode.Off)
        {
            auto ltoFlag = config.lto.toFlag();
            if (!ltoFlag.empty) flags ~= ltoFlag;
        }
        
        // Sanitizers
        foreach (san; config.sanitizers)
        {
            auto sanFlag = san.toFlag();
            if (!sanFlag.empty) flags ~= sanFlag;
        }
        
        // Includes
        foreach (inc; config.base.includeDirs) flags ~= "-I" ~ inc;
        
        // Defines
        foreach (def; config.base.defines) flags ~= "-D" ~ def;
        
        // Extra flags
        flags ~= config.base.extraFlags;
        
        return flags;
    }
    
    /// Build linker flags from compiled config
    protected string[] buildLinkerFlags(CompiledConfig config) pure nothrow
    {
        string[] flags;
        
        // Library directories
        foreach (libDir; config.libDirs) flags ~= "-L" ~ libDir;
        
        // Libraries
        foreach (lib; config.libs) flags ~= "-l" ~ lib;
        foreach (lib; config.sysLibs) flags ~= "-l" ~ lib;
        
        // PIE
        if (config.pie && config.outputType == OutputType.Executable) flags ~= "-pie";
        
        // Strip
        if (config.strip) flags ~= "-s";
        
        // LTO (needs to be in linker flags too)
        if (config.lto != LtoMode.Off)
        {
            auto ltoFlag = config.lto.toFlag();
            if (!ltoFlag.empty) flags ~= ltoFlag;
        }
        
        // Sanitizers (need linking too)
        foreach (san; config.sanitizers)
        {
            auto sanFlag = san.toFlag();
            if (!sanFlag.empty) flags ~= sanFlag;
        }
        
        // Custom linker flags
        flags ~= config.linkerFlags;
        
        return flags;
    }
    
    /// Compile single file with caching
    protected CompileFileResult compileFileWithCaching(
        string source,
        string objDir,
        string[] cmd,
        string targetId,
        string[string] metadata
    ) @system
    {
        CompileFileResult result;
        result.sourceFile = source;
        result.objectFile = buildPath(objDir, baseName(source).stripExtension ~ ".o");
        
        // Create action ID
        ActionId actionId;
        actionId.targetId = targetId;
        actionId.type = ActionType.Compile;
        actionId.subId = source;
        actionId.inputHash = FastHash.hashFile(source);
        
        // Check cache
        if (actionCache.isCached(actionId, [source], metadata))
        {
            if (exists(result.objectFile))
            {
                structuredLog.debug_("cached_compile_").field("detail", "[Cached] " ~ baseName(source)).emit();
                result.success = true;
                result.fromCache = true;
                return result;
            }
        }
        
        // Ensure output directory exists
        auto objDirPath = dirName(result.objectFile);
        if (!exists(objDirPath)) mkdirRecurse(objDirPath);
        
        // Execute compilation
        structuredLog.debug_("compiling_").field("detail", "Compiling: " ~ baseName(source)).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Compilation failed for " ~ source ~ ":\n" ~ res.output;
            actionCache.update(actionId, [source], [], metadata, false);
            return result;
        }
        
        // Extract warnings
        if (!res.output.empty && res.output.canFind("warning"))
        {
            foreach (line; res.output.splitLines())
            {
                if (line.canFind("warning")) result.warnings ~= line;
            }
        }
        
        // Update cache
        actionCache.update(actionId, [source], [result.objectFile], metadata, true);
        
        result.success = true;
        return result;
    }
    
    /// Link objects into final output
    protected LinkResult linkObjects(
        const(string[]) objects,
        string outputFile,
        string[] cmd
    ) @system
    {
        LinkResult result;
        
        // Ensure output directory exists
        auto outDir = dirName(outputFile);
        if (!exists(outDir)) mkdirRecurse(outDir);
        
        structuredLog.info("linking_").field("detail", "Linking: " ~ baseName(outputFile)).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Linking failed:\n" ~ res.output;
            return result;
        }
        
        // Extract warnings
        if (!res.output.empty && res.output.canFind("warning"))
        {
            foreach (line; res.output.splitLines())
            {
                if (line.canFind("warning")) result.warnings ~= line;
            }
        }
        
        result.success = true;
        result.output = outputFile;
        if (exists(outputFile)) result.outputHash = FastHash.hashFile(outputFile);
        
        return result;
    }
    
    /// Parse Makefile-style dependency file
    protected string[] parseDependencyFile(string source, string objDir) @system
    {
        string depFile = buildPath(objDir, baseName(source).stripExtension ~ ".d");
        if (!exists(depFile)) return [];
        
        try
        {
            auto content = readText(depFile).replace("\\\n", " ");
            string[] deps;
            
            foreach (line; content.splitLines())
            {
                auto colonIdx = line.indexOf(':');
                if (colonIdx >= 0) line = line[colonIdx + 1 .. $];
                
                foreach (dep; line.split())
                {
                    auto d = dep.strip;
                    if (!d.empty && exists(d) && d != source) deps ~= d;
                }
            }
            return deps;
        }
        catch (Exception) { return []; }
    }
    
    /// Parse #include directives from source
    protected Import[] parseIncludes(string content, string sourceFile) @system
    {
        Import[] imports;
        auto includeRegex = regex(`#include\s*[<"]([^>"]+)[>"]`);
        
        foreach (match; matchAll(content, includeRegex))
        {
            auto isExternal = match.hit.canFind('<');
            imports ~= Import(
                match[1],
                isExternal ? ImportKind.External : ImportKind.Relative,
                SourceLocation(sourceFile, 0, 0)
            );
        }
        
        return imports;
    }
    
    /// Get platform-specific output extension
    protected string getPlatformExtension(OutputType type) pure nothrow
    {
        final switch (type)
        {
            case OutputType.Executable:
                version(Windows) return ".exe";
                else return "";
            case OutputType.SharedLib:
                version(Windows) return ".dll";
                else version(OSX) return ".dylib";
                else return ".so";
            case OutputType.StaticLib:
                version(Windows) return ".lib";
                else return ".a";
            case OutputType.Object:
                return ".o";
            case OutputType.HeaderOnly:
                return "";
        }
    }
    
    /// Get library prefix
    protected string getLibraryPrefix(OutputType type) pure nothrow
    {
        final switch (type)
        {
            case OutputType.SharedLib:
            case OutputType.StaticLib:
                version(Windows) return "";
                else return "lib";
            case OutputType.Executable:
            case OutputType.Object:
            case OutputType.HeaderOnly:
                return "";
        }
    }
    
    /// Resolve output path from target and config
    protected string resolveOutputPath(
        in Target target,
        in WorkspaceConfig config,
        OutputType outputType,
        string outputDir
    ) @system
    {
        string outDir = outputDir.empty ? config.options.outputDir : outputDir;
        
        if (!target.outputPath.empty)
            return buildPath(outDir, target.outputPath);
        
        auto name = target.name.split(":")[$ - 1];
        string prefix = getLibraryPrefix(outputType);
        string ext = getPlatformExtension(outputType);
        
        return buildPath(outDir, prefix ~ name ~ ext);
    }
    
    /// Create error result with proper code
    protected UnifiedBuildResult createError(string message, BuildErrorCode code)
    {
        return UnifiedBuildResult.err(message, code);
    }
    
    /// Create success result
    protected UnifiedBuildResult createSuccess(string[] outputs, string hash)
    {
        return UnifiedBuildResult.ok(outputs, hash);
    }
}

