module languages.compiled.ocaml.core.handler;

import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.conv;
import std.string : lineSplitter, strip, startsWith, indexOf;
import languages.compiled.base;
import languages.compiled.ocaml.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import infrastructure.utils.security : execute;
import engine.caching.actions.action : ActionId, ActionType;
import engine.linking.incremental;

/// OCaml build handler with dune, ocamlopt, and ocamlc support
class OCamlHandler : BaseCompiledLanguageHandler
{
    private OCamlConfig _config;
    private IncrementalLinker incLinker;
    private bool useIncrementalLink;
    
    this() { super(null); }
    
    // ===== Required Overrides =====
    
    override string languageName() const pure nothrow @safe => "OCaml";
    
    override string[] fileExtensions() const pure nothrow @safe => [".ml", ".mli", ".mll", ".mly"];
    
    override bool detectToolchain() @system
    {
        return isDuneAvailable() || isOcamlOptAvailable() || isOcamlCAvailable();
    }
    
    override string getToolchainVersion() @system
    {
        if (_config.compiler == OCamlCompiler.Dune && isDuneAvailable())
            return "Dune " ~ getDuneVersion();
        if (isOcamlOptAvailable())
            return "OCaml " ~ getOcamlVersion();
        if (isOcamlCAvailable())
            return "OCaml (bytecode)";
        return "unknown";
    }
    
    override void parseConfig(in Target target, in WorkspaceConfig config) @system
    {
        _config = OCamlConfig.init;
        
        string configKey = "ocaml" in target.langConfig ? "ocaml" :
                          ("ocamlConfig" in target.langConfig ? "ocamlConfig" : "");
        
        if (!configKey.empty)
        {
            try { _config = OCamlConfig.fromJSON(parseJSON(target.langConfig[configKey])); }
            catch (Exception e) { structuredLog.warning("failed_to_parse_ocaml_config").field("error", e.msg).emit(); }
        }
        
        // Apply target flags if not in langConfig
        if (!target.flags.empty && configKey.empty)
            _config.compilerFlags ~= target.flags;
    }
    
    override FormatResult formatSources(in string[] sources) @system
    {
        FormatResult result;
        result.success = true;
        
        if (!_config.runFormat || !isOcamlFormatAvailable())
            return result;
        
        structuredLog.debug_("running_ocamlformat").emit();
        
        foreach (file; sources)
        {
            if (extension(file) != ".ml" && extension(file) != ".mli") continue;
            
            try
            {
                auto fmtResult = execute(["ocamlformat", "--inplace", file]);
                if (fmtResult.status != 0)
                    structuredLog.warning("failed_to_format").field("file", file).emit();
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_format").field("file", file).field("error", e.msg).emit();
            }
        }
        
        return result;
    }
    
    override LintResult lintSources(in string[] sources) @system
    {
        LintResult result;
        result.success = true;
        // OCaml doesn't have a standard linter - type checking happens during compilation
        return result;
    }
    
    override CompiledLanguageResult compileTarget(
        in Target target,
        in WorkspaceConfig config,
        in string[] sources
    ) @system
    {
        // Filter for ML files
        string[] mlFiles = sources.filter!(s => 
            extension(s) == ".ml" || extension(s) == ".mli" ||
            extension(s) == ".mll" || extension(s) == ".mly"
        ).array;
        
        if (mlFiles.empty)
        {
            CompiledLanguageResult result;
            result.error = "No .ml files found in sources";
            return result;
        }
        
        // Auto-detect compiler if set to Auto
        if (_config.compiler == OCamlCompiler.Auto)
            _config.compiler = detectCompiler();
        
        // Build based on compiler type
        final switch (_config.compiler)
        {
            case OCamlCompiler.Dune:
                return buildWithDune(target, config);
            case OCamlCompiler.OCamlOpt:
                return buildWithOCamlOpt(target, config, mlFiles);
            case OCamlCompiler.OCamlC:
                return buildWithOCamlC(target, config, mlFiles);
            case OCamlCompiler.OCamlBuild:
                return buildWithOCamlBuild(target, config);
            case OCamlCompiler.Auto:
                CompiledLanguageResult result;
                result.error = "Failed to auto-detect OCaml compiler";
                return result;
        }
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        string outputDir = _config.outputDir.empty ? config.options.outputDir : _config.outputDir;
        
        if (!target.outputPath.empty)
            return [buildPath(outputDir, target.outputPath)];
        
        auto name = target.name.split(":")[$ - 1];
        
        if (_config.outputType == OCamlOutputType.Bytecode)
            name ~= ".byte";
        else version(Windows)
            if (_config.outputType == OCamlOutputType.Executable)
                name ~= ".exe";
        
        return [buildPath(outputDir, name)];
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        Import[] imports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source)) continue;
            
            try
            {
                auto content = readText(source);
                size_t lineNum = 1;
                
                foreach (line; content.lineSplitter)
                {
                    string trimmed = line.strip;
                    if (trimmed.startsWith("open "))
                    {
                        string moduleName = trimmed[5 .. $].strip;
                        auto semicolon = moduleName.indexOf(';');
                        if (semicolon >= 0) moduleName = moduleName[0 .. semicolon].strip;
                        
                        if (!moduleName.empty)
                        {
                            Import imp;
                            imp.moduleName = moduleName;
                            imp.kind = ImportKind.External;
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
    
    // ===== Private Build Methods =====
    
    private void ensureIncLinker() @system
    {
        if (incLinker is null)
        {
            incLinker = new IncrementalLinker(".builder-cache/linking/ocaml", actionCache);
            useIncrementalLink = incLinker.isIncrementalAvailable();
            
            if (useIncrementalLink)
                structuredLog.debug_("ocaml_incremental_link_enabled")
                    .field("linker", incLinker.getLinkerConfig().type.to!string).emit();
        }
    }
    
    private CompiledLanguageResult buildWithDune(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        
        if (!isDuneAvailable())
        {
            result.error = "dune not found. Install with: opam install dune";
            return result;
        }
        
        structuredLog.debug_("building_with_dune").emit();
        
        // Build metadata for cache validation
        string[string] metadata;
        metadata["profile"] = _config.duneProfile == DuneProfile.Dev ? "dev" : "release";
        metadata["targets"] = _config.duneTargets.join(",");
        metadata["duneVersion"] = getDuneVersion();
        
        // Create action ID
        string[] allSources;
        if (exists("dune")) allSources ~= "dune";
        else if (exists("dune-project")) allSources ~= "dune-project";
        allSources ~= target.sources.filter!(s => exists(s)).array;
        
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "dune_build";
        actionId.inputHash = FastHash.hashStrings(allSources);
        
        string expectedOutput = buildPath(_config.outputDir, "default");
        
        // Check cache
        if (actionCache.isCached(actionId, allSources, metadata) && exists(expectedOutput))
        {
            structuredLog.debug_("cached_dune_build").field("target", target.name).emit();
            result.success = true;
            result.outputs = [expectedOutput];
            return result;
        }
        
        // Build command
        string[] cmd = ["dune", "build", "--profile", _config.duneProfile == DuneProfile.Dev ? "dev" : "release"];
        if (!_config.duneTargets.empty) cmd ~= _config.duneTargets;
        if (_config.verbose) cmd ~= "--verbose";
        
        try
        {
            auto duneResult = execute(cmd);
            
            if (duneResult.status != 0)
            {
                result.error = "dune build failed:\n" ~ duneResult.output;
                actionCache.update(actionId, allSources, [], metadata, false);
                return result;
            }
            
            result.success = true;
            result.outputs = [expectedOutput];
            actionCache.update(actionId, allSources, result.outputs, metadata, true);
        }
        catch (Exception e)
        {
            result.error = "Failed to execute dune: " ~ e.msg;
            actionCache.update(actionId, allSources, [], metadata, false);
        }
        
        return result;
    }
    
    private CompiledLanguageResult buildWithOCamlOpt(
        in Target target, in WorkspaceConfig config, in string[] mlFiles
    ) @system
    {
        CompiledLanguageResult result;
        
        if (!isOcamlOptAvailable())
        {
            result.error = "ocamlopt not found. Install OCaml native compiler.";
            return result;
        }
        
        structuredLog.debug_("building_with_ocamlopt").emit();
        ensureIncLinker();
        
        // Build metadata
        string[string] metadata;
        metadata["compiler"] = "ocamlopt";
        metadata["optimize"] = _config.optimize.to!string;
        metadata["debugInfo"] = _config.debugInfo.to!string;
        
        // Determine output file
        string outputDir = _config.outputDir.empty ? config.options.outputDir : _config.outputDir;
        if (!exists(outputDir)) mkdirRecurse(outputDir);
        
        string outputName = _config.outputName.empty ? target.name.split(":")[$ - 1] : _config.outputName;
        string outputPath = buildPath(outputDir, outputName);
        
        // Create action ID
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "ocamlopt";
        actionId.inputHash = FastHash.hashStrings(mlFiles.dup);
        
        // Check cache
        if (actionCache.isCached(actionId, mlFiles, metadata) && exists(outputPath))
        {
            structuredLog.debug_("cached_ocamlopt").field("output", outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            return result;
        }
        
        // Build command
        string[] cmd = ["ocamlopt"];
        
        if (_config.optimize != OptLevel.None)
            cmd ~= "-O" ~ (cast(int)_config.optimize).to!string;
        if (_config.debugInfo) cmd ~= "-g";
        
        // Add include directories
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
        foreach (inc; _config.includeDirs) cmd ~= ["-I", inc];
        foreach (libDir; _config.libDirs) cmd ~= ["-L", libDir];
        foreach (lib; _config.libs) cmd ~= ["-l", lib];
        cmd ~= _config.compilerFlags;
        cmd ~= ["-o", outputPath];
        
        // Order source files (non-main first)
        string[] nonMainFiles, mainFiles;
        foreach (file; mlFiles)
        {
            if (baseName(file).startsWith("main.")) mainFiles ~= file;
            else nonMainFiles ~= file;
        }
        cmd ~= nonMainFiles;
        cmd ~= mainFiles;
        
        try
        {
            auto compileResult = execute(cmd);
            
            if (compileResult.status != 0)
            {
                result.error = "ocamlopt compilation failed:\n" ~ compileResult.output;
                actionCache.update(actionId, mlFiles.dup, [], metadata, false);
                if (incLinker !is null) incLinker.invalidate(outputPath);
                return result;
            }
            
            result.success = true;
            result.outputs = [outputPath];
            actionCache.update(actionId, mlFiles.dup, [outputPath], metadata, true);
            
            if (incLinker !is null)
                incLinker.recordLink(outputPath, mlFiles.dup, _config.libs, _config.compilerFlags.join(" "), false);
        }
        catch (Exception e)
        {
            result.error = "Failed to execute ocamlopt: " ~ e.msg;
            actionCache.update(actionId, mlFiles.dup, [], metadata, false);
        }
        
        return result;
    }
    
    private CompiledLanguageResult buildWithOCamlC(
        in Target target, in WorkspaceConfig config, in string[] mlFiles
    ) @system
    {
        CompiledLanguageResult result;
        
        if (!isOcamlCAvailable())
        {
            result.error = "ocamlc not found. Install OCaml compiler.";
            return result;
        }
        
        structuredLog.debug_("building_with_ocamlc").emit();
        
        // Build metadata
        string[string] metadata;
        metadata["compiler"] = "ocamlc";
        metadata["debugInfo"] = _config.debugInfo.to!string;
        
        // Determine output file
        string outputDir = _config.outputDir.empty ? config.options.outputDir : _config.outputDir;
        if (!exists(outputDir)) mkdirRecurse(outputDir);
        
        string outputName = _config.outputName.empty ? target.name.split(":")[$ - 1] : _config.outputName;
        if (!outputName.endsWith(".byte")) outputName ~= ".byte";
        string outputPath = buildPath(outputDir, outputName);
        
        // Create action ID
        ActionId actionId;
        actionId.targetId = target.name;
        actionId.type = ActionType.Compile;
        actionId.subId = "ocamlc";
        actionId.inputHash = FastHash.hashStrings(mlFiles.dup);
        
        // Check cache
        if (actionCache.isCached(actionId, mlFiles, metadata) && exists(outputPath))
        {
            structuredLog.debug_("cached_ocamlc").field("output", outputPath).emit();
            result.success = true;
            result.outputs = [outputPath];
            return result;
        }
        
        // Build command
        string[] cmd = ["ocamlc"];
        if (_config.debugInfo) cmd ~= "-g";
        
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
        foreach (inc; _config.includeDirs) cmd ~= ["-I", inc];
        foreach (libDir; _config.libDirs) cmd ~= ["-L", libDir];
        foreach (lib; _config.libs) cmd ~= ["-l", lib];
        cmd ~= _config.compilerFlags;
        cmd ~= ["-o", outputPath];
        
        string[] nonMainFiles, mainFiles;
        foreach (file; mlFiles)
        {
            if (baseName(file).startsWith("main.")) mainFiles ~= file;
            else nonMainFiles ~= file;
        }
        cmd ~= nonMainFiles;
        cmd ~= mainFiles;
        
        try
        {
            auto compileResult = execute(cmd);
            
            if (compileResult.status != 0)
            {
                result.error = "ocamlc compilation failed:\n" ~ compileResult.output;
                actionCache.update(actionId, mlFiles.dup, [], metadata, false);
                return result;
            }
            
            result.success = true;
            result.outputs = [outputPath];
            actionCache.update(actionId, mlFiles.dup, [outputPath], metadata, true);
        }
        catch (Exception e)
        {
            result.error = "Failed to execute ocamlc: " ~ e.msg;
            actionCache.update(actionId, mlFiles.dup, [], metadata, false);
        }
        
        return result;
    }
    
    private CompiledLanguageResult buildWithOCamlBuild(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        
        if (!isOcamlBuildAvailable())
        {
            result.error = "ocamlbuild not found. Install with: opam install ocamlbuild";
            return result;
        }
        
        structuredLog.debug_("building_with_ocamlbuild").emit();
        
        string entryFile = _config.entry;
        if (entryFile.empty && !target.sources.empty)
        {
            foreach (source; target.sources)
                if (baseName(source) == "main.ml") { entryFile = source; break; }
            if (entryFile.empty) entryFile = target.sources[0];
        }
        
        string target_ext = _config.outputType == OCamlOutputType.Bytecode ? ".byte" : ".native";
        string targetName = stripExtension(baseName(entryFile)) ~ target_ext;
        
        string[] cmd = ["ocamlbuild", targetName];
        if (!_config.compilerFlags.empty)
            cmd ~= ["-cflags", _config.compilerFlags.join(",")];
        
        try
        {
            auto buildResult = execute(cmd);
            
            if (buildResult.status != 0)
            {
                result.error = "ocamlbuild failed:\n" ~ buildResult.output;
                return result;
            }
            
            result.success = true;
            result.outputs = [buildPath("_build", targetName)];
        }
        catch (Exception e)
        {
            result.error = "Failed to execute ocamlbuild: " ~ e.msg;
        }
        
        return result;
    }
    
    // ===== Private Helpers =====
    
    private OCamlCompiler detectCompiler() @system
    {
        if (isDuneAvailable() && (exists("dune-project") || exists("dune")))
            return OCamlCompiler.Dune;
        if (isOcamlBuildAvailable() && exists("_tags"))
            return OCamlCompiler.OCamlBuild;
        if (isOcamlOptAvailable())
            return OCamlCompiler.OCamlOpt;
        if (isOcamlCAvailable())
            return OCamlCompiler.OCamlC;
        return OCamlCompiler.OCamlOpt;
    }
    
    private bool isDuneAvailable() @system
    {
        try { return execute(["dune", "--version"]).status == 0; }
        catch (Exception) { return false; }
    }
    
    private string getDuneVersion() @system
    {
        try
        {
            auto result = execute(["dune", "--version"]);
            return result.status == 0 ? result.output.strip : "unknown";
        }
        catch (Exception) { return "unknown"; }
    }
    
    private string getOcamlVersion() @system
    {
        try
        {
            auto result = execute(["ocamlopt", "-version"]);
            return result.status == 0 ? result.output.strip : "unknown";
        }
        catch (Exception) { return "unknown"; }
    }
    
    private bool isOcamlOptAvailable() @system
    {
        try { return execute(["ocamlopt", "-version"]).status == 0; }
        catch (Exception) { return false; }
    }
    
    private bool isOcamlCAvailable() @system
    {
        try { return execute(["ocamlc", "-version"]).status == 0; }
        catch (Exception) { return false; }
    }
    
    private bool isOcamlBuildAvailable() @system
    {
        try { return execute(["ocamlbuild", "-version"]).status == 0; }
        catch (Exception) { return false; }
    }
    
    private bool isOcamlFormatAvailable() @system
    {
        try { return execute(["ocamlformat", "--version"]).status == 0; }
        catch (Exception) { return false; }
    }
}
