module infrastructure.config.macros.compiler;

import std.process;
import std.file;
import std.path;
import std.conv;
import std.algorithm;
import std.string;
import infrastructure.config.schema.schema;
import infrastructure.errors;

/// D code compiler interface for runtime macro compilation
/// 
/// Compiles D code at build time and loads it dynamically for macro execution.
/// This enables maximum flexibility - write any D code and execute it as a macro.

/// Compiler configuration
struct CompilerConfig
{
    string compiler = "ldc2";  // or "dmd", "gdc"
    string[] flags = ["-O2"];
    string[] importPaths;
    string outputDir = ".builder-cache/macros";
    bool verbose = false;
}

/// Compilation result
struct CompilationResult
{
    bool success;
    string output;
    string error;
    string binaryPath;
}

/// D code compiler
class DCompiler
{
    private CompilerConfig config;
    
    this(CompilerConfig config = CompilerConfig.init) pure nothrow @safe
    {
        this.config = config;
    }
    
    /// Compile D source code to executable
    BuildResult!CompilationResult compile(string source, string outputName) @system
    {
        CompilationResult result;
        
        try
        {
            // Create output directory
            if (!exists(config.outputDir))
                mkdirRecurse(config.outputDir);
            
            // Write source to temporary file
            string sourceFile = buildPath(config.outputDir, outputName ~ ".d");
            std.file.write(sourceFile, source);
            
            // Build compiler command
            string[] cmd = [config.compiler];
            cmd ~= config.flags;
            cmd ~= ["-of=" ~ buildPath(config.outputDir, outputName)];
            
            // Add import paths
            foreach (importPath; config.importPaths)
                cmd ~= "-I" ~ importPath;
            
            cmd ~= sourceFile;
            
            if (config.verbose)
            {
                import infrastructure.utils.logging;
                structuredLog.debug_("compiling_macro_").field("detail", "Compiling macro: " ~ cmd.join(" ")).emit();
            }
            
            // Execute compiler
            auto execResult = execute(cmd);
            
            result.output = execResult.output;
            result.success = execResult.status == 0;
            result.binaryPath = buildPath(config.outputDir, outputName);
            
            if (!result.success)
            {
                result.error = execResult.output;
                return BuildResult!CompilationResult.err(
                    Errors.language("D", "Macro compilation failed: " ~ result.error, Language.MacroExpansionFailed)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
            
            return BuildResult!CompilationResult.ok(result);
        }
        catch (Exception e)
        {
            result.success = false;
            result.error = e.msg;
            return BuildResult!CompilationResult.err(
                Errors.language("D", "Macro compilation exception: " ~ e.msg, Language.MacroExpansionFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Compile D file
    BuildResult!CompilationResult compileFile(string filePath) @system
    {
        if (!exists(filePath))
        {
            return BuildResult!CompilationResult.err(
                Errors.io(filePath, "Macro file not found: " ~ filePath, IO.FileNotFound)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        auto source = std.file.readText(filePath);
        auto outputName = filePath.baseName.stripExtension;
        return compile(source, outputName);
    }
    
    /// Check if macro is already compiled and up-to-date
    bool isCached(string sourceFile) const @system
    {
        string outputPath = buildPath(config.outputDir, sourceFile.baseName.stripExtension);
        
        if (!exists(outputPath))
            return false;
        
        if (!exists(sourceFile))
            return false;
        
        // Check if binary is newer than source
        auto sourceMod = sourceFile.timeLastModified;
        auto binaryMod = outputPath.timeLastModified;
        
        return binaryMod > sourceMod;
    }
}

/// Macro execution result
struct MacroResult
{
    bool success;
    string output;
    string error;
    Target[] targets;
}

/// Macro executor
class MacroExecutor
{
    /// Execute compiled macro binary
    BuildResult!MacroResult execute(string binaryPath, string[] args = []) @system
    {
        MacroResult result;
        
        if (!exists(binaryPath))
        {
            result.success = false;
            result.error = "Macro binary not found: " ~ binaryPath;
            return BuildResult!MacroResult.err(
                Errors.io(binaryPath, result.error, IO.FileNotFound)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        try
        {
            // Execute macro
            auto cmd = [binaryPath] ~ args;
            auto execResult = std.process.execute(cmd);
            
            result.output = execResult.output;
            result.success = execResult.status == 0;
            
            if (!result.success)
            {
                result.error = execResult.output;
                return BuildResult!MacroResult.err(
                    Errors.language("D", "Macro execution failed: " ~ result.error, Language.MacroExpansionFailed)
                        .withLocation(__FILE__, __LINE__)
                        .build()
                );
            }
            
            // Parse output as target definitions (JSON format)
            result.targets = parseTargetOutput(result.output);
            
            return BuildResult!MacroResult.ok(result);
        }
        catch (Exception e)
        {
            result.success = false;
            result.error = e.msg;
            return BuildResult!MacroResult.err(
                Errors.language("D", "Macro execution exception: " ~ e.msg, Language.MacroExpansionFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Parse macro output to targets
    private Target[] parseTargetOutput(string output) @system
    {
        import std.json;
        
        Target[] targets;
        
        try
        {
            auto json = parseJSON(output);
            if (json.type != JSONType.array)
                return targets;
            
            foreach (targetJson; json.array)
            {
                Target target;
                target.name = targetJson["name"].str;
                target.type = targetJson["type"].str.to!TargetType;
                
                if ("language" in targetJson)
                    import std.conv : to;
                    import std.uni : toLower;
                    auto langStr = targetJson["language"].str.toLower();
                    switch (langStr)
                    {
                        case "d": target.language = TargetLanguage.D; break;
                        case "python": case "py": target.language = TargetLanguage.Python; break;
                        case "javascript": case "js": target.language = TargetLanguage.JavaScript; break;
                        case "typescript": case "ts": target.language = TargetLanguage.TypeScript; break;
                        case "go": target.language = TargetLanguage.Go; break;
                        case "rust": case "rs": target.language = TargetLanguage.Rust; break;
                        case "cpp": case "c++": case "cxx": target.language = TargetLanguage.Cpp; break;
                        case "c": target.language = TargetLanguage.C; break;
                        default: target.language = TargetLanguage.Generic; break;
                    }
                
                if ("sources" in targetJson)
                {
                    foreach (src; targetJson["sources"].array)
                        target.sources ~= src.str;
                }
                
                if ("deps" in targetJson)
                {
                    foreach (dep; targetJson["deps"].array)
                        target.deps ~= dep.str;
                }
                
                targets ~= target;
            }
        }
        catch (Exception e)
        {
            // If parsing fails, return empty array
            import infrastructure.utils.logging;
            structuredLog.warning("failed_to_parse_macro_output_").field("detail", "Failed to parse macro output: " ~ e.msg).emit();
        }
        
        return targets;
    }
}

/// High-level macro compilation and execution interface
class MacroBuilder
{
    private DCompiler compiler;
    private MacroExecutor executor;
    
    this(CompilerConfig config = CompilerConfig.init) @system
    {
        compiler = new DCompiler(config);
        executor = new MacroExecutor();
    }
    
    /// Compile and execute D macro
    BuildResult!MacroResult build(string sourceFile, string[] args = []) @system
    {
        // Check cache
        if (compiler.isCached(sourceFile))
        {
            string binaryPath = buildPath(
                compiler.config.outputDir,
                sourceFile.baseName.stripExtension
            );
            return executor.execute(binaryPath, args);
        }
        
        // Compile macro
        auto compileResult = compiler.compileFile(sourceFile);
        if (compileResult.isErr)
            return BuildResult!MacroResult.err(compileResult.unwrapErr());
        
        auto compilation = compileResult.unwrap();
        
        // Execute compiled macro
        return executor.execute(compilation.binaryPath, args);
    }
    
    /// Compile and execute inline D code
    BuildResult!MacroResult buildInline(string source, string name, string[] args = []) @system
    {
        auto compileResult = compiler.compile(source, name);
        if (compileResult.isErr)
            return BuildResult!MacroResult.err(compileResult.unwrapErr());
        
        auto compilation = compileResult.unwrap();
        return executor.execute(compilation.binaryPath, args);
    }
}

