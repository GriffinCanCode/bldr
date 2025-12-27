module languages.compiled.cpp.builders.incremental;

import std.algorithm;
import std.array;
import std.conv;
import std.file;
import std.path;
import std.process;
import std.string;
import languages.compiled.cpp.core.config;
// import toolchain; // Replaced by unified toolchain system
import infrastructure.toolchain.core.spec;
import languages.compiled.cpp.builders.base;
import languages.compiled.cpp.analysis.incremental;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import engine.compilation.incremental.engine;
import engine.compilation.incremental.ast_engine;
import engine.caching.incremental.dependency;
import engine.caching.incremental.ast_dependency;
import engine.caching.actions.action;
import infrastructure.analysis.ast.parser;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.errors;

/// Incremental C++ builder with AST-level dependency tracking
/// Only recompiles files/symbols affected by changes
class IncrementalCppBuilder : BaseCppBuilder
{
    private const(Toolchain)* toolchain;
    private ActionCache actionCache;
    private DependencyCache depCache;
    private ASTDependencyCache astCache;
    private IncrementalEngine incEngine;
    private HybridIncrementalEngine astEngine;
    private CppDependencyAnalyzer analyzer;
    private bool useASTLevel;
    
    this(CppConfig config, ActionCache actionCache = null, DependencyCache depCache = null, bool enableASTLevel = true)
    {
        super(config);
        
        // Detect compiler toolchain using unified toolchain system
        import infrastructure.toolchain.detection.detector : AutoDetector;
        import infrastructure.toolchain.registry.registry : ToolchainRegistry;
        
        auto registry = ToolchainRegistry.instance();
        
        // Try to find appropriate C++ compiler toolchain
        // Priority: config-specified > clang > gcc
        if (!config.customCompiler.empty)
        {
            // Look for specific compiler by name
            auto toolchains = registry.getByName(config.customCompiler);
            if (!toolchains.empty)
                this.toolchain = &toolchains[0];
        }
        else
        {
            // Auto-detect based on compiler preference
            auto detector = new AutoDetector();
            auto allToolchains = detector.detectAll();
            
            // Find C++ capable toolchain
            foreach (ref tc; allToolchains)
            {
                auto compiler = tc.getToolByName("g++");
                if (compiler is null)
                    compiler = tc.getToolByName("clang++");
                
                if (compiler !is null && compiler.type == ToolchainType.Compiler)
                {
                    this.toolchain = &tc;
                    break;
                }
            }
        }
        
        if (this.toolchain is null)
            structuredLog.warning("no_c_compiler_toolchain_detected_build_m").emit();
        
        // Initialize caches
        if (actionCache is null)
        {
            auto cacheConfig = ActionCacheConfig.fromEnvironment();
            this.actionCache = new ActionCache(".builder-cache/actions/cpp", cacheConfig);
        }
        else
        {
            this.actionCache = actionCache;
        }
        
        if (depCache is null)
        {
            this.depCache = new DependencyCache(".builder-cache/incremental/cpp");
        }
        else
        {
            this.depCache = depCache;
        }
        
        // Initialize AST cache
        this.astCache = new ASTDependencyCache(".builder-cache/ast-incremental/cpp");
        
        // Initialize incremental engines
        this.incEngine = new IncrementalEngine(this.depCache, this.actionCache);
        
        auto astIncEngine = new ASTIncrementalEngine(this.astCache, this.depCache, this.actionCache);
        this.astEngine = new HybridIncrementalEngine(astIncEngine, enableASTLevel);
        this.useASTLevel = enableASTLevel;
        
        // Initialize dependency analyzer
        this.analyzer = new CppDependencyAnalyzer(config.includeDirs);
        
        // Initialize AST parsers
        initializeASTParsers();
        
        if (enableASTLevel)
            structuredLog.info("astlevel_incremental_compilation_enabled").emit();
    }
    
    override CppCompileResult build(
        in string[] sources,
        in CppConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        CppCompileResult result;
        
        if (toolchain is null || !toolchain.isComplete())
        {
            result.error = "Compiler toolchain not available: " ~ config.compiler.to!string;
            return result;
        }
        
        structuredLog.info("incremental_c_compilation_with_").field("detail", "Incremental C++ compilation with " ~ toolchain.name).emit();
        
        // Separate C and C++ files
        string[] cppFiles;
        string[] cFiles;
        
        foreach (source; sources)
        {
            string ext = extension(source).toLower;
            if (ext == ".cpp" || ext == ".cxx" || ext == ".cc" || ext == ".C" || ext == ".c++")
                cppFiles ~= source;
            else if (ext == ".c")
                cFiles ~= source;
        }
        
        // Determine output paths
        string outputFile = determineOutputPath(config, target, workspace);
        string outputDir = dirName(outputFile);
        string objDir = determineObjDir(config, workspace);
        
        // Ensure directories exist
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        if (!exists(objDir))
            mkdirRecurse(objDir);
        
        // Compile with incremental optimization
        string[] cppObjects;
        if (!cppFiles.empty)
        {
            auto cppResult = compileIncremental(
                cppFiles, config, objDir, true, target, workspace
            );
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
            auto cResult = compileIncremental(
                cFiles, config, objDir, false, target, workspace
            );
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
        
        // Combine and link
        string[] allObjects = cppObjects ~ cObjects;
        result.objects = allObjects;
        
        auto linkResult = linkObjects(
            allObjects, outputFile, config, !cppFiles.empty, target
        );
        if (!linkResult.success)
        {
            result.error = linkResult.error;
            return result;
        }
        
        result.success = true;
        result.outputs = [outputFile];
        result.outputHash = FastHash.hashFile(outputFile);
        
        // Log incremental statistics
        auto stats = incEngine.getStats();
        structuredLog.info("incremental_compilation_complete_").field("detail", "Incremental compilation complete: " ~
                      stats.validDependencies.to!string ~ " dependencies tracked").emit();
        
        return result;
    }
    
    /// Compile files with incremental dependency tracking
    private CppCompileResult compileIncremental(
        string[] sources,
        in CppConfig config,
        string objDir,
        bool isCpp,
        in Target target,
        in WorkspaceConfig workspace
    ) @system
    {
        CppCompileResult result;
        result.success = true;
        
        // Get appropriate compiler from toolchain
        const(Tool)* compilerTool = isCpp ? 
            toolchain.getToolByName("g++") : 
            toolchain.getToolByName("gcc");
        
        // Fallback to clang if gcc not available
        if (compilerTool is null)
            compilerTool = isCpp ? 
                toolchain.getToolByName("clang++") : 
                toolchain.getToolByName("clang");
        
        if (compilerTool is null)
        {
            result.success = false;
            result.error = "No suitable compiler found in toolchain";
            return result;
        }
        
        string compiler = compilerTool.path;
        
        auto flags = buildCompilerFlags(config, isCpp);
        
        // Build metadata for cache
        string[string] baseMetadata;
        baseMetadata["compiler"] = compiler;
        baseMetadata["flags"] = flags.join(" ");
        baseMetadata["isCpp"] = isCpp.to!string;
        
        // Detect changed files (simplified - would integrate with file watching)
        string[] changedFiles;
        foreach (source; sources)
        {
            auto depResult = depCache.getDependencies(source);
            if (depResult.isErr || !depResult.unwrap().isValid())
                changedFiles ~= source;
        }
        
        // Try AST-level analysis first if enabled
        string[] filesToCompile;
        if (useASTLevel && changedFiles.length > 0)
        {
            structuredLog.debug_("attempting_astlevel_incremental_analysis").emit();
            auto astAnalysisResult = astEngine.analyzeChanges(sources, changedFiles);
            
            if (astAnalysisResult.isOk)
            {
                auto astAnalysis = astAnalysisResult.unwrap();
                filesToCompile = astAnalysis.filesToRebuild.dup;
                
                structuredLog.info("astlevel_granularity_").field("detail", "AST-level granularity: " ~ 
                          astAnalysis.granularity.to!string[0..min(5, $)] ~ "% of symbols changed").emit();
                
                // Log symbol-level rebuild info
                foreach (file, symbols; astAnalysis.symbolsToRecompile)
                {
                    structuredLog.debug_("__").field("detail", "  " ~ baseName(file) ~ ": " ~ symbols).emit();
                }
            }
            else
            {
                structuredLog.warning("astlevel_analysis_failed_falling_back_to").field("detail", "AST-level analysis failed, falling back to file-level: " ~
                             astAnalysisResult.unwrapErr().message()).emit();
                filesToCompile = changedFiles.dup;
            }
        }
        else
        {
            // Use traditional file-level incremental compilation
            auto rebuildResult = incEngine.determineRebuildSet(
                sources,
                changedFiles,
                (file) {
                    ActionId actionId;
                    actionId.targetId = target.name;
                    actionId.type = ActionType.Compile;
                    actionId.subId = baseName(file);
                    actionId.inputHash = FastHash.hashFile(file);
                    return actionId;
                },
                (file) => baseMetadata
            );
            
            filesToCompile = rebuildResult.filesToCompile.dup;
            
            structuredLog.info("incremental_").field("detail", "Incremental: " ~ rebuildResult.compiledFiles.to!string ~ 
                       " files to compile, " ~ rebuildResult.cachedFiles_.to!string ~ 
                       " cached (" ~ rebuildResult.reductionRate.to!string[0..min(5, $)] ~ "%)").emit();
        }
        
        // Compile only necessary files
        foreach (source; filesToCompile)
        {
            auto compileResult = compileOneFile(
                source, compiler, flags, objDir, target, baseMetadata
            );
            
            if (!compileResult.success)
            {
                result.success = false;
                result.error = compileResult.error;
                result.hadWarnings = compileResult.hadWarnings;
                result.warnings ~= compileResult.warnings;
                return result;
            }
            
            result.objects ~= compileResult.objects;
            result.warnings ~= compileResult.warnings;
            result.hadWarnings = result.hadWarnings || compileResult.hadWarnings;
        }
        
        // Add cached object files (files not in rebuild list)
        foreach (source; sources)
        {
            if (!filesToCompile.canFind(source))
            {
                string objFile = buildPath(objDir, baseName(source).stripExtension ~ ".o");
                if (exists(objFile))
                {
                    result.objects ~= objFile;
                    structuredLog.debug_("__using_cached_").field("detail", "  [Using Cached] " ~ objFile).emit();
                }
            }
        }
        
        return result;
    }
    
    /// Compile a single file and record dependencies
    private CppCompileResult compileOneFile(
        string source,
        string compiler,
        string[] flags,
        string objDir,
        in Target target,
        string[string] metadata
    ) @system
    {
        CppCompileResult result;
        
        string objFile = buildPath(objDir, baseName(source).stripExtension ~ ".o");
        
        // Analyze dependencies before compilation
        auto depsResult = analyzer.analyzeDependencies(source);
        string[] dependencies;
        if (depsResult.isOk)
        {
            dependencies = depsResult.unwrap();
            structuredLog.debug_("__dependencies_for_").field("detail", "  Dependencies for " ~ source ~ ": " ~ 
                          dependencies.length.to!string).emit();
        }
        
        // Build compile command
        string[] cmd = [compiler];
        cmd ~= flags;
        cmd ~= ["-c", source];
        cmd ~= ["-o", objFile];
        
        structuredLog.info("compiling_").field("detail", "Compiling: " ~ source).emit();
        structuredLog.debug_("__command_").field("detail", "  Command: " ~ cmd.join(" ")).emit();
        
        // Execute compilation
        auto res = execute(cmd);
        bool success = (res.status == 0);
        
        if (!success)
        {
            result.success = false;
            result.error = "Compilation failed for " ~ source ~ ": " ~ res.output;
            return result;
        }
        
        // Check for warnings
        if (!res.output.empty)
        {
            result.hadWarnings = true;
            result.warnings ~= "In " ~ source ~ ": " ~ res.output;
        }
        
        // Record successful compilation with dependencies
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = baseName(source);
        actionId.inputHash = FastHash.hashFile(source);
        
        incEngine.recordCompilation(
            source,
            dependencies,
            actionId,
            [objFile],
            metadata
        );
        
        result.success = true;
        result.objects = [objFile];
        return result;
    }
    
    /// Link object files
    private CppCompileResult linkObjects(
        string[] objects,
        string outputFile,
        in CppConfig config,
        bool isCpp,
        in Target target
    ) @system
    {
        CppCompileResult result;
        
        // Use compiler as linker (standard practice)
        const(Tool)* linkerTool = isCpp ? 
            toolchain.getToolByName("g++") : 
            toolchain.getToolByName("gcc");
        
        if (linkerTool is null)
            linkerTool = isCpp ? 
                toolchain.getToolByName("clang++") : 
                toolchain.getToolByName("clang");
        
        if (linkerTool is null)
        {
            result.error = "No suitable linker found in toolchain";
            return result;
        }
        
        string linker = linkerTool.path;
        
        auto linkerFlags = buildLinkerFlags(config);
        
        // Build link command
        string[] cmd = [linker];
        cmd ~= ["-o", outputFile];
        cmd ~= objects;
        cmd ~= linkerFlags;
        
        structuredLog.info("linking_").field("detail", "Linking: " ~ outputFile).emit();
        structuredLog.debug_("__command_").field("detail", "  Command: " ~ cmd.join(" ")).emit();
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Linking failed: " ~ res.output;
            return result;
        }
        
        if (!res.output.empty)
        {
            result.hadWarnings = true;
            result.warnings ~= "Linker: " ~ res.output;
        }
        
        result.success = true;
        return result;
    }
    
    private string determineOutputPath(
        in CppConfig config,
        in Target target,
        in WorkspaceConfig workspace
    ) @system
    {
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
        return outputFile;
    }
    
    private string determineObjDir(
        in CppConfig config,
        in WorkspaceConfig workspace
    ) @system
    {
        string objDir = config.objDir;
        if (!objDir.isAbsolute)
            objDir = buildPath(workspace.options.outputDir, objDir);
        return objDir;
    }
    
    override bool isAvailable()
    {
        return toolchain !is null && toolchain.isComplete();
    }
    
    override string name() const
    {
        if (toolchain is null)
            return "IncrementalBuilder (no toolchain)";
        return "IncrementalBuilder (" ~ toolchain.name ~ ")";
    }
    
    override string getVersion()
    {
        if (toolchain is null)
            return "unknown";
        auto compiler = toolchain.compiler();
        if (compiler is null)
            return "unknown";
        return compiler.version_.toString();
    }
    
    override bool supportsFeature(string feature)
    {
        switch (feature)
        {
            case "incremental":
            case "dependency_tracking":
                return true;
            default:
                return super.supportsFeature(feature);
        }
    }
}

