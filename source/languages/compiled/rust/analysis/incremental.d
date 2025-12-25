module languages.compiled.rust.analysis.incremental;

import std.algorithm;
import std.array;
import std.file;
import std.path;
import std.regex;
import std.string;
import std.process;
import std.json;
import engine.compilation.incremental.analyzer;
import infrastructure.utils.logging.logger;
import infrastructure.errors;

/// Rust incremental dependency analyzer
/// Uses cargo metadata for accurate dependency tracking
final class RustDependencyAnalyzer : BaseDependencyAnalyzer
{
    private string projectRoot;
    private JSONValue cargoMetadata;
    private bool metadataLoaded;
    
    this(string projectRoot) @system
    {
        this.projectRoot = projectRoot;
        this.metadataLoaded = false;
        
        // Rust standard library paths
        version(Posix)
        {
            this.systemPaths = [
                "~/.rustup/toolchains",
                "/usr/local/lib/rustlib"
            ];
        }
        version(Windows)
        {
            this.systemPaths = [
                "%USERPROFILE%\\.rustup\\toolchains"
            ];
        }
        
        loadCargoMetadata();
    }
    
    /// Analyze Rust module dependencies
    override BuildResult!(string[]) analyzeDependencies(
        string sourceFile,
        string[] additionalSearchPaths = []
    ) @system
    {
        if (!exists(sourceFile) || !isFile(sourceFile))
        {
            return BuildResult!(string[]).err(
                Errors.generic("Source file not found: " ~ sourceFile, ErrorCode.FileNotFound)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
        
        try
        {
            // Parse mod and use statements
            auto deps = parseRustModules(sourceFile);
            
            string[] resolvedDeps;
            string sourceDir = dirName(sourceFile);
            
            foreach (dep; deps)
            {
                if (isExternalDependency(dep))
                {
                    Logger.debugLog("  [External] " ~ dep);
                    continue;
                }
                
                // Resolve module to file
                string resolved = resolveRustModule(dep, sourceDir);
                
                if (!resolved.empty && exists(resolved))
                {
                    resolvedDeps ~= buildNormalizedPath(resolved);
                    Logger.debugLog("  [Resolved] " ~ dep ~ " -> " ~ resolved);
                }
            }
            
            return BuildResult!(string[]).ok(resolvedDeps);
        }
        catch (Exception e)
        {
            return BuildResult!(string[]).err(
                Errors.generic("Failed to analyze Rust dependencies for " ~ 
                             sourceFile ~ ": " ~ e.msg,
                             ErrorCode.AnalysisFailed)
                    .withLocation(__FILE__, __LINE__)
                    .build()
            );
        }
    }
    
    /// Check if dependency is external (std, external crate)
    override bool isExternalDependency(string moduleName) @system
    {
        // Standard library modules
        static immutable string[] stdModules = [
            "std", "core", "alloc", "proc_macro"
        ];
        
        foreach (prefix; stdModules)
        {
            if (moduleName == prefix || moduleName.startsWith(prefix ~ "::"))
                return true;
        }
        
        // Check if it's an external crate from Cargo.toml
        if (metadataLoaded && "packages" in cargoMetadata)
        {
            foreach (pkg; cargoMetadata["packages"].array)
            {
                auto name = pkg["name"].str;
                if (moduleName.startsWith(name))
                    return true;
            }
        }
        
        return super.isExternalDependency(moduleName);
    }
    
    private void loadCargoMetadata() @system
    {
        try
        {
            string cargoToml = buildPath(projectRoot, "Cargo.toml");
            if (!exists(cargoToml))
                return;
            
            // Run cargo metadata
            auto result = execute(["cargo", "metadata", "--format-version", "1"]);
            if (result.status == 0)
            {
                cargoMetadata = parseJSON(result.output);
                metadataLoaded = true;
                Logger.debugLog("Loaded Cargo metadata");
            }
        }
        catch (Exception e)
        {
            Logger.debugLog("Failed to load Cargo metadata: " ~ e.msg);
        }
    }
    
    private string[] parseRustModules(string sourceFile) @system
    {
        string[] modules;
        
        auto content = readText(sourceFile);
        
        // Match mod statements: mod foo; mod bar;
        auto modRegex = regex(r"mod\s+(\w+)\s*;", "gm");
        foreach (match; matchAll(content, modRegex))
        {
            if (match.length > 1)
                modules ~= match[1];
        }
        
        // Match use statements: use foo::bar; use super::baz;
        auto useRegex = regex(r"use\s+((?:self|super|crate|::)?[\w:]+)", "gm");
        foreach (match; matchAll(content, useRegex))
        {
            if (match.length > 1)
            {
                auto used = match[1];
                // Extract the root module
                auto parts = used.split("::");
                if (!parts.empty)
                    modules ~= parts[0];
            }
        }
        
        return modules.sort().uniq().array;
    }
    
    private string resolveRustModule(string moduleName, string sourceDir) @system
    {
        // Try module_name.rs in same directory
        string sameDir = buildPath(sourceDir, moduleName ~ ".rs");
        if (exists(sameDir))
            return sameDir;
        
        // Try module_name/mod.rs
        string modDir = buildPath(sourceDir, moduleName, "mod.rs");
        if (exists(modDir))
            return modDir;
        
        // Try in project src directory
        string srcDir = buildPath(projectRoot, "src");
        string srcFile = buildPath(srcDir, moduleName ~ ".rs");
        if (exists(srcFile))
            return srcFile;
        
        string srcMod = buildPath(srcDir, moduleName, "mod.rs");
        if (exists(srcMod))
            return srcMod;
        
        return "";
    }
}

/// Rust incremental compilation helper
struct RustIncrementalHelper
{
    /// Find affected sources when a module changes
    static string[] findAffectedSources(
        string changedFile,
        string[] allSources,
        RustDependencyAnalyzer analyzer
    ) @system
    {
        string[] affected;
        string normalizedChanged = buildNormalizedPath(changedFile);
        
        foreach (source; allSources)
        {
            auto depsResult = analyzer.analyzeDependencies(source);
            if (depsResult.isErr)
                continue;
            
            auto deps = depsResult.unwrap();
            
            if (deps.canFind(normalizedChanged))
            {
                affected ~= source;
                Logger.debugLog("  " ~ source ~ " affected by " ~ changedFile);
            }
        }
        
        return affected;
    }
}

