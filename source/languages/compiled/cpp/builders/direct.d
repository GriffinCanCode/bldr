module languages.compiled.cpp.builders.direct;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.compiled.cpp.core.config;
import infrastructure.toolchain;
import languages.compiled.cpp.builders.base;
import languages.compiled.cpp.builders.modules : ModuleBuilder;
import languages.compiled.cpp.analysis.modules : isModuleInterface;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;
import engine.caching.modules.bmi : BMICache, BMICacheConfig;

/// Direct compiler builder - compiles without external build system with action-level caching
class DirectBuilder : BaseCppBuilder
{
    private Toolchain toolchain;
    private ActionCache actionCache;
    private BMICache bmiCache;
    private ModuleBuilder moduleBuilder;
    
    this(CppConfig config, ActionCache cache = null, BMICache bmiCacheParam = null)
    {
        super(config);
        // Get toolchain from registry
        auto registry = ToolchainRegistry.instance();
        registry.initialize();
        
        if (config.compiler == Compiler.Custom && !config.customCompiler.empty)
        {
            // Handle custom compiler path
            toolchain = createCustomToolchain(config.customCompiler);
        }
        else if (config.compiler != Compiler.Auto)
        {
            // Get specific compiler by name
            string tcName;
            final switch (config.compiler)
            {
                case Compiler.Auto: tcName = ""; break;
                case Compiler.GCC: tcName = "gcc"; break;
                case Compiler.Clang: tcName = "clang"; break;
                case Compiler.MSVC: tcName = "msvc"; break;
                case Compiler.Intel: tcName = "intel"; break;
                case Compiler.Custom: tcName = ""; break;
            }
            
            if (!tcName.empty)
            {
                auto tcs = registry.getByName(tcName);
                if (!tcs.empty)
                    toolchain = tcs[$ - 1]; // Get latest version
            }
        }
        else
        {
            // Auto-detect best available
            auto result = registry.findFor(Platform.host(), ToolchainType.Compiler);
            if (result.isOk)
                toolchain = result.unwrap();
        }
        if (cache is null)
        {
            auto cacheConfig = ActionCacheConfig.fromEnvironment();
            actionCache = new ActionCache(".builder-cache/actions/cpp", cacheConfig);
        }
        else
        {
            actionCache = cache;
        }
        
        // Initialize BMI cache for C++20 modules
        if (bmiCacheParam is null)
        {
            auto bmiConfig = BMICacheConfig.fromEnvironment();
            bmiCache = new BMICache(".builder-cache/bmi", bmiConfig);
        }
        else
        {
            bmiCache = bmiCacheParam;
        }
        
        // Initialize module builder (lazy - only when modules enabled)
        if (config.modules)
            moduleBuilder = new ModuleBuilder(toolchain, bmiCache);
    }
    
    override CppCompileResult build(
        in string[] sources,
        in CppConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        CppCompileResult result;
        
        if (toolchain.tools.empty)
        {
            result.error = "Compiler not available: " ~ config.compiler.to!string;
            return result;
        }
        
        auto compiler = toolchain.compiler();
        if (compiler is null)
        {
            result.error = "No compiler found in toolchain";
            return result;
        }
        
        structuredLog.debug_("direct_compilation_with_").field("detail", "Direct compilation with " ~ toolchain.name ~ " v" ~ compiler.version_.toString()).emit();
        
        // Separate C, C++, and module files
        string[] cppFiles;
        string[] cFiles;
        string[] moduleFiles;
        
        foreach (source; sources)
        {
            if (isModuleInterface(source))
                moduleFiles ~= source;
            else
            {
                string ext = extension(source).toLower;
                if (ext == ".cpp" || ext == ".cxx" || ext == ".cc" || ext == ".C" || ext == ".c++")
                    cppFiles ~= source;
                else if (ext == ".c")
                    cFiles ~= source;
            }
        }
        
        // Determine output file
        string outputFile = config.output;
        if (outputFile.empty && !target.outputPath.empty)
        {
            outputFile = buildPath(workspace.options.outputDir, target.outputPath);
        }
        else if (outputFile.empty)
        {
            auto name = target.name.split(":")[$ - 1];
            outputFile = buildPath(workspace.options.outputDir, name);
        }
        
        // Ensure output directory exists
        string outputDir = dirName(outputFile);
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Create object directory
        string objDir = config.objDir;
        if (!objDir.isAbsolute)
            objDir = buildPath(workspace.options.outputDir, objDir);
        
        if (!exists(objDir))
            mkdirRecurse(objDir);
        
        // Compile C++20 modules first (if any)
        string[] moduleObjects;
        if (!moduleFiles.empty && config.modules)
        {
            if (moduleBuilder is null)
                moduleBuilder = new ModuleBuilder(toolchain, bmiCache);
            
            structuredLog.debug_("building_c20_modules_with_bmi_caching").emit();
            moduleObjects = moduleBuilder.buildModuleProject(
                cast(string[])moduleFiles ~ cast(string[])cppFiles, 
                objDir, 
                config
            );
            
            if (moduleObjects.empty && (!moduleFiles.empty || !cppFiles.empty))
            {
                result.error = "Module compilation failed";
                return result;
            }
            
            // Module builder handles all C++ sources when modules are present
            cppFiles = [];
        }
        
        // Compile regular C++ files (when not using modules)
        string[] cppObjects;
        if (!cppFiles.empty)
        {
            auto cppResult = compileFiles(cppFiles, config, objDir, true, target);
            if (!cppResult.success)
            {
                result.error = cppResult.error;
                result.hadWarnings = cppResult.hadWarnings;
                result.warnings = cppResult.warnings;
                return result;
            }
            cppObjects = cppResult.objects;
            result.warnings ~= cppResult.warnings;
            result.hadWarnings = result.hadWarnings || cppResult.hadWarnings;
        }
        
        // Compile C files
        string[] cObjects;
        if (!cFiles.empty)
        {
            auto cResult = compileFiles(cFiles, config, objDir, false, target);
            if (!cResult.success)
            {
                result.error = cResult.error;
                result.hadWarnings = cResult.hadWarnings || result.hadWarnings;
                result.warnings ~= cResult.warnings;
                return result;
            }
            cObjects = cResult.objects;
            result.warnings ~= cResult.warnings;
            result.hadWarnings = result.hadWarnings || cResult.hadWarnings;
        }
        
        // Combine all objects
        string[] allObjects = moduleObjects ~ cppObjects ~ cObjects;
        result.objects = allObjects;
        
        // Link (use C++ linker if we have any C++ code or modules)
        bool hasCpp = !cppObjects.empty || !moduleObjects.empty;
        auto linkResult = linkObjects(allObjects, outputFile, config, hasCpp, target);
        if (!linkResult.success)
        {
            result.error = linkResult.error;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputFile];
        result.outputHash = FastHash.hashFile(outputFile);
        
        return result;
    }
    
    override bool isAvailable()
    {
        return !toolchain.tools.empty && toolchain.isComplete();
    }
    
    override string name() const
    {
        return "DirectBuilder (" ~ toolchain.name ~ ")";
    }
    
    override string getVersion()
    {
        auto compiler = toolchain.compiler();
        return compiler ? compiler.version_.toString() : "unknown";
    }
    
    private Toolchain createCustomToolchain(string compilerPath)
    {
        Toolchain tc;
        tc.name = "custom";
        tc.id = "custom-compiler";
        tc.host = Platform.host();
        tc.target = Platform.host();
        
        Tool tool;
        tool.name = "custom";
        tool.path = compilerPath;
        tool.type = ToolchainType.Compiler;
        tool.version_ = Version(0, 0, 0);
        tc.tools ~= tool;
        
        return tc;
    }
    
    override bool supportsFeature(string feature)
    {
        switch (feature)
        {
            case "compile":
            case "link":
            case "object":
            case "pch":
            case "lto":
            case "sanitizers":
            case "modules":
            case "header-units":
                return true;
            default:
                return super.supportsFeature(feature);
        }
    }
    
    /// Get BMI cache for C++20 modules
    BMICache getBMICache() @safe => bmiCache;
    
    /// Flush all caches to disk
    void flushCaches() @system
    {
        actionCache.flush();
        if (bmiCache !is null)
            bmiCache.flush();
    }
    
    /// Compile source files to object files with action-level caching
    private CppCompileResult compileFiles(
        string[] sources,
        in CppConfig config,
        string objDir,
        bool isCpp,
        in Target target
    )
    {
        CppCompileResult result;
        result.success = true;
        
        // Get compiler path
        auto comp = toolchain.compiler();
        if (comp is null)
        {
            CppCompileResult errorResult;
            errorResult.error = "No compiler available in toolchain";
            return errorResult;
        }
        
        string compiler = comp.path;
        // For C++, try to find g++ or clang++ variant
        if (isCpp && (comp.name == "gcc" || comp.name == "clang"))
        {
            import std.string : replace;
            compiler = comp.path.replace("gcc", "g++").replace("clang", "clang++");
        }
        
        auto flags = buildCompilerFlags(config, isCpp);
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["compiler"] = compiler;
        metadata["flags"] = flags.join(" ");
        metadata["isCpp"] = isCpp.to!string;
        
        foreach (source; sources)
        {
            // Generate object file path
            string objFile = buildPath(objDir, baseName(source).stripExtension ~ ".o");
            
            // Create action ID for this compilation
            ActionId actionId;
            actionId.targetId = target.name;
            actionId.type = ActionType.Compile;
            actionId.subId = baseName(source);
            actionId.inputHash = FastHash.hashFile(source);
            
            // Check if this compilation is cached
            if (actionCache.isCached(actionId, [source], metadata) && exists(objFile))
            {
                structuredLog.debug_("__cached_").field("detail", "  [Cached] " ~ source).emit();
                result.objects ~= objFile;
                continue;
            }
            
            // Build compile command
            string[] cmd = [compiler];
            cmd ~= flags;
            cmd ~= ["-c", source];
            cmd ~= ["-o", objFile];
            
            structuredLog.debug_("compiling_").field("detail", "Compiling: " ~ source).emit();
            structuredLog.debug_("__command_").field("detail", "  Command: " ~ cmd.join(" ")).emit();
            
            // Execute compilation
            auto res = execute(cmd);
            
            bool success = (res.status == 0);
            
            if (!success)
            {
                result.success = false;
                result.error = "Compilation failed for " ~ source ~ ": " ~ res.output;
                
                // Update cache with failure
                actionCache.update(
                    actionId,
                    [source],
                    [],
                    metadata,
                    false
                );
                
                return result;
            }
            
            // Check for warnings
            if (!res.output.empty)
            {
                result.hadWarnings = true;
                result.warnings ~= "In " ~ source ~ ": " ~ res.output;
            }
            
            // Update cache with success
            actionCache.update(
                actionId,
                [source],
                [objFile],
                metadata,
                true
            );
            
            result.objects ~= objFile;
        }
        
        return result;
    }
    
    /// Link object files to final output with action-level caching
    private CppCompileResult linkObjects(
        string[] objects,
        string outputFile,
        in CppConfig config,
        bool isCpp,
        in Target target
    )
    {
        CppCompileResult result;
        
        // Use C++ compiler for linking if any C++ code
        // Get compiler/linker path
        auto comp = toolchain.compiler();
        if (comp is null)
        {
            CppCompileResult errorResult;
            errorResult.error = "No compiler available in toolchain for linking";
            return errorResult;
        }
        
        string linker = comp.path;
        // For C++, use g++ or clang++ for linking
        if (isCpp && (comp.name == "gcc" || comp.name == "clang"))
        {
            import std.string : replace;
            linker = comp.path.replace("gcc", "g++").replace("clang", "clang++");
        }
        
        // Build linker flags
        auto linkerFlags = buildLinkerFlags(config);
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["linker"] = linker;
        metadata["linkerFlags"] = linkerFlags.join(" ");
        metadata["isCpp"] = isCpp.to!string;
        
        // Create action ID for linking
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Link;
        actionId.subId = baseName(outputFile);
        // Hash all object files together for input hash
        actionId.inputHash = FastHash.hashStrings(objects);
        
        // Check if linking is cached
        if (actionCache.isCached(actionId, objects, metadata) && exists(outputFile))
        {
            structuredLog.debug_("__cached_linking_").field("detail", "  [Cached] Linking: " ~ outputFile).emit();
            result.success = true;
            return result;
        }
        
        // Build link command
        string[] cmd = [linker];
        
        // Output file
        cmd ~= ["-o", outputFile];
        
        // Object files
        cmd ~= objects;
        
        // Linker flags
        cmd ~= linkerFlags;
        
        structuredLog.debug_("linking_").field("detail", "Linking: " ~ outputFile).emit();
        structuredLog.debug_("__command_").field("detail", "  Command: " ~ cmd.join(" ")).emit();
        
        // Execute linking
        auto res = execute(cmd);
        
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.error = "Linking failed: " ~ res.output;
            
            // Update cache with failure
            actionCache.update(
                actionId,
                objects,
                [],
                metadata,
                false
            );
            
            return result;
        }
        
        // Check for warnings
        if (!res.output.empty)
        {
            result.hadWarnings = true;
            result.warnings ~= "Linker: " ~ res.output;
        }
        
        // Update cache with success
        actionCache.update(
            actionId,
            objects,
            [outputFile],
            metadata,
            true
        );
        
        result.success = true;
        return result;
    }
}

