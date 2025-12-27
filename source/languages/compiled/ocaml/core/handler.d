module languages.compiled.ocaml.core.handler;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import std.process;
import std.string : lineSplitter, strip;
import languages.base.base;
import languages.base.mixins;
import languages.compiled.ocaml.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache, ActionCacheConfig, ActionId, ActionType;

/// OCaml build handler with support for dune, ocamlopt, and ocamlc with action-level caching
class OCamlHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"ocaml";
    
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        structuredLog.debug_("building_ocaml_target_").field("detail", "Building OCaml target: " ~ target.name).emit();
        
        // Parse OCaml configuration
        OCamlConfig ocamlConfig = parseOCamlConfig(target, config);
        
        // Validate sources
        if (target.sources.empty)
        {
            result.error = "No OCaml source files specified";
            return result;
        }
        
        // Filter for .ml files
        string[] mlFiles;
        foreach (source; target.sources)
        {
            string ext = extension(source);
            if (ext == ".ml" || ext == ".mli" || ext == ".mll" || ext == ".mly")
            {
                mlFiles ~= source;
            }
        }
        
        if (mlFiles.empty)
        {
            result.error = "No .ml files found in sources";
            return result;
        }
        
        // Run formatter if requested
        if (ocamlConfig.runFormat && isOcamlFormatAvailable())
        {
            structuredLog.debug_("running_ocamlformat").emit();
            formatCode(mlFiles);
        }
        
        // Auto-detect compiler if set to Auto
        if (ocamlConfig.compiler == OCamlCompiler.Auto)
        {
            ocamlConfig.compiler = detectCompiler();
        }
        
        // Build based on compiler type
        final switch (ocamlConfig.compiler)
        {
            case OCamlCompiler.Dune:
                result = buildWithDune(target, config, ocamlConfig);
                break;
            case OCamlCompiler.OCamlOpt:
                result = buildWithOCamlOpt(target, config, ocamlConfig, mlFiles);
                break;
            case OCamlCompiler.OCamlC:
                result = buildWithOCamlC(target, config, ocamlConfig, mlFiles);
                break;
            case OCamlCompiler.OCamlBuild:
                result = buildWithOCamlBuild(target, config, ocamlConfig);
                break;
            case OCamlCompiler.Auto:
                // This shouldn't happen as we detect above, but handle it
                result.error = "Failed to auto-detect OCaml compiler";
                break;
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        OCamlConfig ocamlConfig = parseOCamlConfig(target, config);
        
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            string outputDir = ocamlConfig.outputDir.empty ? 
                              config.options.outputDir : 
                              ocamlConfig.outputDir;
            
            // Add extension based on platform and output type
            if (ocamlConfig.outputType == OCamlOutputType.Bytecode)
            {
                name ~= ".byte";
            }
            else
            {
                version(Windows)
                {
                    if (ocamlConfig.outputType == OCamlOutputType.Executable)
                        name ~= ".exe";
                }
            }
            
            outputs ~= buildPath(outputDir, name);
        }
        
        return outputs;
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
                auto imports = parseOCamlImports(source, content);
                allImports ~= imports;
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_analyze_imports_in_").field("detail", "Failed to analyze imports in " ~ source ~ ": " ~ e.msg).emit();
            }
        }
        
        return allImports;
    }
    
    private LanguageBuildResult buildWithDune(
        in Target target,
        in WorkspaceConfig config,
        OCamlConfig ocamlConfig
    )
    {
        LanguageBuildResult result;
        
        if (!isDuneAvailable())
        {
            result.error = "dune not found. Install with: opam install dune";
            return result;
        }
        
        structuredLog.debug_("building_with_dune").emit();
        
        // Collect all ML sources for cache tracking
        string[] allSources;
        if (exists("dune") || exists("dune-project"))
        {
            allSources ~= exists("dune") ? "dune" : "dune-project";
        }
        foreach (source; target.sources)
        {
            if (exists(source))
                allSources ~= source;
        }
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["profile"] = ocamlConfig.duneProfile == DuneProfile.Dev ? "dev" : "release";
        metadata["targets"] = ocamlConfig.duneTargets.join(",");
        metadata["duneVersion"] = getDuneVersion();
        
        // Create action ID for this dune build
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "dune_build";
        actionId.inputHash = FastHash.hashStrings(allSources);
        
        // Determine expected output
        string expectedOutput = buildPath(ocamlConfig.outputDir, "default");
        
        // Check if build is cached
        if (actionCache.isCached(actionId, allSources, metadata) && exists(expectedOutput))
        {
            structuredLog.debug_("__cached_dune_build_").field("detail", "  [Cached] dune build: " ~ target.name).emit();
            result.success = true;
            result.outputs = [expectedOutput];
            return result;
        }
        
        // Build command
        string[] cmd = ["dune", "build"];
        
        // Add profile
        cmd ~= ["--profile", ocamlConfig.duneProfile == DuneProfile.Dev ? "dev" : "release"];
        
        // Add specific targets if specified
        if (!ocamlConfig.duneTargets.empty)
        {
            cmd ~= ocamlConfig.duneTargets;
        }
        
        // Add verbose flag
        if (ocamlConfig.verbose)
        {
            cmd ~= "--verbose";
        }
        
        // Execute dune build
        try
        {
            auto duneResult = execute(cmd);
            
            bool success = (duneResult.status == 0);
            
            if (!success)
            {
                result.error = "dune build failed:\n" ~ duneResult.output;
                
                // Update cache with failure
                actionCache.update(
                    actionId,
                    allSources,
                    [],
                    metadata,
                    false
                );
                
                return result;
            }
            
            // Parse output for warnings
            if (!duneResult.output.empty)
            {
                structuredLog.info("log_event").field("message", duneResult.output).emit();
            }
            
            result.success = true;
            
            // Dune outputs to _build directory by default
            result.outputs = [expectedOutput];
            
            // Update cache with success
            actionCache.update(
                actionId,
                allSources,
                result.outputs,
                metadata,
                true
            );
            
            return result;
        }
        catch (Exception e)
        {
            result.error = "Failed to execute dune: " ~ e.msg;
            
            // Update cache with failure
            actionCache.update(
                actionId,
                allSources,
                [],
                metadata,
                false
            );
            
            return result;
        }
    }
    
    private LanguageBuildResult buildWithOCamlOpt(
        in Target target,
        in WorkspaceConfig config,
        OCamlConfig ocamlConfig,
        in string[] mlFiles
    )
    {
        LanguageBuildResult result;
        
        if (!isOcamlOptAvailable())
        {
            result.error = "ocamlopt not found. Install OCaml native compiler.";
            return result;
        }
        
        structuredLog.debug_("building_with_ocamlopt_native_compiler").emit();
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["compiler"] = "ocamlopt";
        metadata["optimize"] = ocamlConfig.optimize.to!string;
        metadata["debugInfo"] = ocamlConfig.debugInfo.to!string;
        metadata["includeDirs"] = ocamlConfig.includeDirs.join(",");
        metadata["libs"] = ocamlConfig.libs.join(",");
        metadata["compilerFlags"] = ocamlConfig.compilerFlags.join(" ");
        
        // Determine output file
        string outputDir = ocamlConfig.outputDir.empty ? 
                          config.options.outputDir : 
                          ocamlConfig.outputDir;
        
        if (!exists(outputDir))
        {
            mkdirRecurse(outputDir);
        }
        
        string outputName = ocamlConfig.outputName.empty ? 
                           target.name.split(":")[$ - 1] : 
                           ocamlConfig.outputName;
        
        string outputPath = buildPath(outputDir, outputName);
        
        // Create action ID for this compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "ocamlopt";
        actionId.inputHash = FastHash.hashStrings(mlFiles.dup);
        
        // Check if compilation is cached
        if (actionCache.isCached(actionId, mlFiles, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_ocamlopt_compilation_").field("detail", "  [Cached] ocamlopt compilation: " ~ outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            return result;
        }
        
        // Determine entry point
        string entryFile = ocamlConfig.entry;
        if (entryFile.empty && !mlFiles.empty)
        {
            // Look for main.ml or use first file
            foreach (file; mlFiles)
            {
                if (baseName(file) == "main.ml")
                {
                    entryFile = file;
                    break;
                }
            }
            if (entryFile.empty)
                entryFile = mlFiles[0];
        }
        
        // Build command
        string[] cmd = ["ocamlopt"];
        
        // Add optimization flags
        if (ocamlConfig.optimize != OptLevel.None)
        {
            cmd ~= "-O" ~ (cast(int)ocamlConfig.optimize).to!string;
        }
        
        // Add debug info
        if (ocamlConfig.debugInfo)
        {
            cmd ~= "-g";
        }
        
        // Add source directories as include directories
        bool[string] seenDirs;
        foreach (source; mlFiles)
        {
            string dir = dirName(source);
            if (dir !in seenDirs && dir != ".")
            {
                seenDirs[dir] = true;
                cmd ~= ["-I", dir];
            }
        }
        
        // Add include directories
        foreach (inc; ocamlConfig.includeDirs)
        {
            cmd ~= ["-I", inc];
        }
        
        // Add library directories
        foreach (libDir; ocamlConfig.libDirs)
        {
            cmd ~= ["-L", libDir];
        }
        
        // Add libraries
        foreach (lib; ocamlConfig.libs)
        {
            cmd ~= ["-l", lib];
        }
        
        // Add compiler flags
        cmd ~= ocamlConfig.compilerFlags;
        
        cmd ~= ["-o", outputPath];
        
        // Add source files in dependency order (utils before main)
        string[] nonMainFiles;
        string[] mainFiles;
        foreach (file; mlFiles)
        {
            if (baseName(file).startsWith("main."))
                mainFiles ~= file;
            else
                nonMainFiles ~= file;
        }
        cmd ~= nonMainFiles;
        cmd ~= mainFiles;
        
        // Execute compilation
        try
        {
            auto compileResult = execute(cmd);
            
            bool success = (compileResult.status == 0);
            
            if (!success)
            {
                result.error = "ocamlopt compilation failed:\n" ~ compileResult.output;
                
                // Update cache with failure
                actionCache.update(
                    actionId,
                    mlFiles.dup,
                    [],
                    metadata,
                    false
                );
                
                return result;
            }
            
            // Check for warnings
            if (!compileResult.output.empty)
            {
                structuredLog.warning("compilation_outputn").field("detail", "Compilation output:\n" ~ compileResult.output).emit();
            }
            
            result.success = true;
            result.outputs = [outputPath];
            
            // Update cache with success
            actionCache.update(
                actionId,
                mlFiles.dup,
                [outputPath],
                metadata,
                true
            );
            
            return result;
        }
        catch (Exception e)
        {
            result.error = "Failed to execute ocamlopt: " ~ e.msg;
            
            // Update cache with failure
            actionCache.update(
                actionId,
                mlFiles.dup,
                [],
                metadata,
                false
            );
            
            return result;
        }
    }
    
    private LanguageBuildResult buildWithOCamlC(
        in Target target,
        in WorkspaceConfig config,
        OCamlConfig ocamlConfig,
        in string[] mlFiles
    )
    {
        LanguageBuildResult result;
        
        if (!isOcamlCAvailable())
        {
            result.error = "ocamlc not found. Install OCaml compiler.";
            return result;
        }
        
        structuredLog.debug_("building_with_ocamlc_bytecode_compiler").emit();
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["compiler"] = "ocamlc";
        metadata["debugInfo"] = ocamlConfig.debugInfo.to!string;
        metadata["includeDirs"] = ocamlConfig.includeDirs.join(",");
        metadata["libs"] = ocamlConfig.libs.join(",");
        metadata["compilerFlags"] = ocamlConfig.compilerFlags.join(" ");
        
        // Determine output file
        string outputDir = ocamlConfig.outputDir.empty ? 
                          config.options.outputDir : 
                          ocamlConfig.outputDir;
        
        if (!exists(outputDir))
        {
            mkdirRecurse(outputDir);
        }
        
        string outputName = ocamlConfig.outputName.empty ? 
                           target.name.split(":")[$ - 1] : 
                           ocamlConfig.outputName;
        
        // Bytecode executables typically have .byte extension
        if (!outputName.endsWith(".byte"))
            outputName ~= ".byte";
        
        string outputPath = buildPath(outputDir, outputName);
        
        // Create action ID for this compilation
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "ocamlc";
        actionId.inputHash = FastHash.hashStrings(mlFiles.dup);
        
        // Check if compilation is cached
        if (actionCache.isCached(actionId, mlFiles, metadata) && exists(outputPath))
        {
            structuredLog.debug_("__cached_ocamlc_compilation_").field("detail", "  [Cached] ocamlc compilation: " ~ outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            return result;
        }
        
        // Determine entry point
        string entryFile = ocamlConfig.entry;
        if (entryFile.empty && !mlFiles.empty)
        {
            // Look for main.ml or use first file
            foreach (file; mlFiles)
            {
                if (baseName(file) == "main.ml")
                {
                    entryFile = file;
                    break;
                }
            }
            if (entryFile.empty)
                entryFile = mlFiles[0];
        }
        
        // Build command (similar to ocamlopt but for bytecode)
        string[] cmd = ["ocamlc"];
        
        // Add debug info
        if (ocamlConfig.debugInfo)
        {
            cmd ~= "-g";
        }
        
        // Add source directories as include directories
        bool[string] seenDirs;
        foreach (source; mlFiles)
        {
            string dir = dirName(source);
            if (dir !in seenDirs && dir != ".")
            {
                seenDirs[dir] = true;
                cmd ~= ["-I", dir];
            }
        }
        
        // Add include directories
        foreach (inc; ocamlConfig.includeDirs)
        {
            cmd ~= ["-I", inc];
        }
        
        // Add library directories
        foreach (libDir; ocamlConfig.libDirs)
        {
            cmd ~= ["-L", libDir];
        }
        
        // Add libraries
        foreach (lib; ocamlConfig.libs)
        {
            cmd ~= ["-l", lib];
        }
        
        // Add compiler flags
        cmd ~= ocamlConfig.compilerFlags;
        
        cmd ~= ["-o", outputPath];
        
        // Add source files in dependency order (utils before main)
        string[] nonMainFiles;
        string[] mainFiles;
        foreach (file; mlFiles)
        {
            if (baseName(file).startsWith("main."))
                mainFiles ~= file;
            else
                nonMainFiles ~= file;
        }
        cmd ~= nonMainFiles;
        cmd ~= mainFiles;
        
        // Execute compilation
        try
        {
            auto compileResult = execute(cmd);
            
            bool success = (compileResult.status == 0);
            
            if (!success)
            {
                result.error = "ocamlc compilation failed:\n" ~ compileResult.output;
                
                // Update cache with failure
                actionCache.update(
                    actionId,
                    mlFiles.dup,
                    [],
                    metadata,
                    false
                );
                
                return result;
            }
            
            // Check for warnings
            if (!compileResult.output.empty)
            {
                structuredLog.warning("compilation_outputn").field("detail", "Compilation output:\n" ~ compileResult.output).emit();
            }
            
            result.success = true;
            result.outputs = [outputPath];
            
            // Update cache with success
            actionCache.update(
                actionId,
                mlFiles.dup,
                [outputPath],
                metadata,
                true
            );
            
            return result;
        }
        catch (Exception e)
        {
            result.error = "Failed to execute ocamlc: " ~ e.msg;
            
            // Update cache with failure
            actionCache.update(
                actionId,
                mlFiles.dup,
                [],
                metadata,
                false
            );
            
            return result;
        }
    }
    
    private LanguageBuildResult buildWithOCamlBuild(
        in Target target,
        in WorkspaceConfig config,
        OCamlConfig ocamlConfig
    )
    {
        LanguageBuildResult result;
        
        if (!isOcamlBuildAvailable())
        {
            result.error = "ocamlbuild not found. Install with: opam install ocamlbuild";
            return result;
        }
        
        structuredLog.debug_("building_with_ocamlbuild").emit();
        
        // Determine entry point
        string entryFile = ocamlConfig.entry;
        if (entryFile.empty && !target.sources.empty)
        {
            // Look for main.ml
            foreach (source; target.sources)
            {
                if (baseName(source) == "main.ml")
                {
                    entryFile = source;
                    break;
                }
            }
            if (entryFile.empty)
                entryFile = target.sources[0];
        }
        
        // Build command
        string[] cmd = ["ocamlbuild"];
        
        // Add native or bytecode target
        string target_ext = ocamlConfig.outputType == OCamlOutputType.Bytecode ? ".byte" : ".native";
        string targetName = stripExtension(baseName(entryFile)) ~ target_ext;
        
        cmd ~= targetName;
        
        // Add flags
        if (!ocamlConfig.compilerFlags.empty)
        {
            cmd ~= ["-cflags", ocamlConfig.compilerFlags.join(",")];
        }
        
        // Execute ocamlbuild
        try
        {
            auto buildResult = execute(cmd);
            
            if (buildResult.status != 0)
            {
                result.error = "ocamlbuild failed:\n" ~ buildResult.output;
                return result;
            }
            
            if (!buildResult.output.empty)
            {
                structuredLog.info("log_event").field("message", buildResult.output).emit();
            }
            
            result.success = true;
            result.outputs = [buildPath("_build", targetName)];
            
            return result;
        }
        catch (Exception e)
        {
            result.error = "Failed to execute ocamlbuild: " ~ e.msg;
            return result;
        }
    }
    
    private OCamlConfig parseOCamlConfig(in Target target, in WorkspaceConfig config)
    {
        OCamlConfig ocamlConfig;
        
        // Try language-specific keys
        string configKey = "";
        if ("ocaml" in target.langConfig)
            configKey = "ocaml";
        else if ("ocamlConfig" in target.langConfig)
            configKey = "ocamlConfig";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                ocamlConfig = OCamlConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_ocaml_config_using_defau").field("detail", "Failed to parse OCaml config, using defaults: " ~ e.msg).emit();
            }
        }
        
        // Apply target flags if not in langConfig
        if (!target.flags.empty && configKey.empty)
        {
            ocamlConfig.compilerFlags ~= target.flags;
        }
        
        return ocamlConfig;
    }
    
    private Import[] parseOCamlImports(string filePath, string content)
    {
        Import[] imports;
        
        // Parse OCaml open statements and module references
        // Simple regex-based parsing for now
        size_t lineNum = 1;
        foreach (line; content.lineSplitter)
        {
            string trimmed = line.strip;
            
            // Match: open ModuleName
            if (trimmed.startsWith("open "))
            {
                string moduleName = trimmed[5 .. $].strip;
                if (!moduleName.empty)
                {
                    // Remove any trailing semicolons or comments
                    import std.string : indexOf;
                    auto semicolon = moduleName.indexOf(';');
                    if (semicolon >= 0)
                        moduleName = moduleName[0 .. semicolon].strip;
                    
                    Import imp;
                    imp.moduleName = moduleName;
                    imp.kind = ImportKind.External;
                    imp.location = SourceLocation(filePath, lineNum, 0);
                    imports ~= imp;
                }
            }
            lineNum++;
        }
        
        return imports;
    }
    
    private OCamlCompiler detectCompiler()
    {
        // Check for dune first (most modern)
        if (isDuneAvailable() && (exists("dune-project") || exists("dune")))
        {
            structuredLog.debug_("detected_dune_project").emit();
            return OCamlCompiler.Dune;
        }
        
        // Check for ocamlbuild
        if (isOcamlBuildAvailable() && exists("_tags"))
        {
            structuredLog.debug_("detected_ocamlbuild_project").emit();
            return OCamlCompiler.OCamlBuild;
        }
        
        // Prefer native compiler if available
        if (isOcamlOptAvailable())
        {
            structuredLog.debug_("using_ocamlopt_native_compiler").emit();
            return OCamlCompiler.OCamlOpt;
        }
        
        // Fallback to bytecode compiler
        if (isOcamlCAvailable())
        {
            structuredLog.debug_("using_ocamlc_bytecode_compiler").emit();
            return OCamlCompiler.OCamlC;
        }
        
        structuredLog.warning("no_ocaml_compiler_found").emit();
        return OCamlCompiler.OCamlOpt; // Return something, error will be raised later
    }
    
    private bool isDuneAvailable()
    {
        try
        {
            auto result = execute(["dune", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    private string getDuneVersion()
    {
        try
        {
            auto result = execute(["dune", "--version"]);
            if (result.status == 0)
                return result.output.strip;
            return "unknown";
        }
        catch (Exception)
        {
            return "unknown";
        }
    }
    
    private bool isOcamlOptAvailable()
    {
        try
        {
            auto result = execute(["ocamlopt", "-version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    private bool isOcamlCAvailable()
    {
        try
        {
            auto result = execute(["ocamlc", "-version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    private bool isOcamlBuildAvailable()
    {
        try
        {
            auto result = execute(["ocamlbuild", "-version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    private bool isOcamlFormatAvailable()
    {
        try
        {
            auto result = execute(["ocamlformat", "--version"]);
            return result.status == 0;
        }
        catch (Exception)
        {
            return false;
        }
    }
    
    private void formatCode(in string[] files)
    {
        foreach (file; files)
        {
            try
            {
                auto result = execute(["ocamlformat", "--inplace", file]);
                if (result.status != 0)
                {
                    structuredLog.warning("failed_to_format_").field("detail", "Failed to format " ~ file).emit();
                }
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_format_").field("detail", "Failed to format " ~ file ~ ": " ~ e.msg).emit();
            }
        }
    }
}


