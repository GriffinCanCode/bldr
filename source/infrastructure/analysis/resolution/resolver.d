module infrastructure.analysis.resolution.resolver;

import std.stdio;
import std.algorithm;
import std.array;
import std.string;
import std.path;
import std.conv;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.errors;
import infrastructure.repository.resolution.resolver : RepositoryResolver;

/// Resolves import statements to build targets
class DependencyResolver
{
    private WorkspaceConfig config;
    private string[string] importCache;
    private ImportIndex index;
    private RepositoryResolver repoResolver;
    
    this(WorkspaceConfig config, string cacheDir = ".builder-cache")
    {
        this.config = config;
        this.index = new ImportIndex(config);
        
        // Initialize repository resolver if repositories are defined
        if (config.repositories.length > 0)
        {
            this.repoResolver = new RepositoryResolver(cacheDir, config.root);
            
            // Register all repository rules
            foreach (ref repo; config.repositories)
            {
                auto result = repoResolver.registerRule(repo);
                if (result.isErr)
                {
                    import infrastructure.utils.logging.logger : Logger;
                    Logger.warning("Failed to register repository " ~ repo.name ~ ": " ~ 
                                 result.unwrapErr().message());
                }
            }
        }
        
        buildImportCache();
    }
    
    /// Resolve a dependency reference to a target name
    string resolve(string dep, string fromTarget)
    {
        // External repository reference: @repo//path:target
        if (dep.startsWith("@"))
        {
            if (repoResolver !is null)
            {
                auto result = repoResolver.resolveTarget(dep);
                if (result.isOk)
                    return result.unwrap();
            }
            // If resolution fails, return as-is (will error later)
            return dep;
        }
        
        // Absolute reference: //path/to:target
        if (dep.startsWith("//"))
            return dep;
        
        // Relative reference: :target (same package)
        if (dep.startsWith(":"))
        {
            auto parts = fromTarget.split(":");
            if (parts.length > 0)
                return parts[0] ~ dep;
        }
        
        // Package-relative: //path/to:target
        return dep;
    }
    
    /// Resolve a dependency reference to a TargetId (type-safe version)
    BuildResult!TargetId resolveToId(string dep, TargetId fromTarget)
    {
        import infrastructure.errors : ParseError;
        
        // External repository reference: @repo//path:target
        if (dep.startsWith("@"))
        {
            if (repoResolver !is null)
            {
                auto result = repoResolver.resolveTarget(dep);
                if (result.isOk)
                {
                    // Convert resolved path to TargetId
                    return TargetId.parse(dep);
                }
                else
                {
                    return BuildResult!TargetId.err(result.unwrapErr());
                }
            }
            else
            {
                auto error = Errors.parse("", "External repository reference but no repositories defined: " ~ dep, ErrorCode.MissingDependency)
                    .withLocation(__FILE__, __LINE__)
                    .build();
                return BuildResult!TargetId.err(error);
            }
        }
        
        // Absolute reference: //path/to:target or workspace//path:target
        if (dep.indexOf("//") >= 0 || dep.indexOf(":") >= 0)
        {
            return TargetId.parse(dep);
        }
        
        // Relative reference: :target (same package)
        if (dep.startsWith(":"))
        {
            auto newName = dep[1 .. $];  // Remove leading ":"
            auto resolved = TargetId(fromTarget.workspace, fromTarget.path, newName);
            return BuildResult!TargetId.ok(resolved);
        }
        
        // Simple name - same workspace and path
        auto resolved = TargetId(fromTarget.workspace, fromTarget.path, dep);
        return BuildResult!TargetId.ok(resolved);
    }
    
    /// Resolve an import statement to a target
    string resolveImport(string importName, TargetLanguage language)
    {
        // Check cache first
        string cacheKey = language.to!string ~ ":" ~ importName;
        if (cacheKey in importCache)
            return importCache[cacheKey];
        
        // Language-specific resolution
        string target;
        
        final switch (language)
        {
            case TargetLanguage.D:
                target = resolveDImport(importName);
                break;
            case TargetLanguage.Python:
                target = resolvePythonImport(importName);
                break;
            case TargetLanguage.JavaScript:
            case TargetLanguage.TypeScript:
                target = resolveJSImport(importName);
                break;
            case TargetLanguage.Go:
                target = resolveGoImport(importName);
                break;
            case TargetLanguage.Rust:
                target = resolveRustImport(importName);
                break;
            case TargetLanguage.Cpp:
            case TargetLanguage.C:
                target = resolveCppImport(importName);
                break;
            case TargetLanguage.Java:
                target = resolveJavaImport(importName);
                break;
            case TargetLanguage.Kotlin:
            case TargetLanguage.Scala:
                target = resolveJavaImport(importName);  // Use Java resolution for JVM languages
                break;
            case TargetLanguage.CSharp:
            case TargetLanguage.FSharp:
                target = resolveDotNetImport(importName);
                break;
            case TargetLanguage.Swift:
                target = resolveSwiftImport(importName);
                break;
            case TargetLanguage.Zig:
            case TargetLanguage.Nim:
                target = resolveCppImport(importName);  // Use C++ resolution for compiled languages
                break;
            case TargetLanguage.Ruby:
                target = resolveRubyImport(importName);
                break;
            case TargetLanguage.Perl:
                target = resolvePerlImport(importName);
                break;
            case TargetLanguage.PHP:
                target = resolvePHPImport(importName);
                break;
            case TargetLanguage.Elixir:
                target = resolveElixirImport(importName);
                break;
            case TargetLanguage.Gleam:
                target = resolveGleamImport(importName);
                break;
            case TargetLanguage.Lua:
                target = resolveLuaImport(importName);
                break;
            case TargetLanguage.R:
                target = resolveRImport(importName);
                break;
            case TargetLanguage.OCaml:
                target = resolveOCamlImport(importName);
                break;
            case TargetLanguage.Haskell:
                target = resolveHaskellImport(importName);
                break;
            case TargetLanguage.Elm:
                target = resolveElmImport(importName);
                break;
            case TargetLanguage.CSS:
                target = "";  // CSS has no imports to resolve
                break;
            case TargetLanguage.Protobuf:
                target = "";  // Protobuf imports handled by compiler
                break;
            case TargetLanguage.Generic:
                target = "";
                break;
        }
        
        if (!target.empty)
            importCache[cacheKey] = target;
        
        return target;
    }
    
    private void buildImportCache()
    {
        // Pre-build cache of known imports to targets
        foreach (ref target; config.targets)
        {
            // Map target sources to import paths
            // This is language-specific
        }
    }
    
    private string resolveDImport(string importName)
    {
        // Convert D module name to potential target
        // e.g., "core.graph" -> "//source/core:graph"
        
        auto parts = importName.split(".");
        if (parts.length > 1)
        {
            string path = parts[0 .. $ - 1].join("/");
            string name = parts[$ - 1];
            
            // Look for matching target
            foreach (ref target; config.targets)
            {
                if (target.name.canFind(path) && target.name.canFind(name))
                    return target.name;
            }
        }
        
        return "";
    }
    
    private string resolvePythonImport(string importName)
    {
        // Convert Python import to target
        // e.g., "mypackage.module" -> "//python/mypackage:module"
        
        auto parts = importName.split(".");
        
        foreach (ref target; config.targets)
        {
            // Check if any source file matches
            foreach (source; target.sources)
            {
                if (source.canFind(importName.replace(".", "/")))
                    return target.name;
            }
        }
        
        return "";
    }
    
    private string resolveJSImport(string importName)
    {
        // Convert JS/TS import to target
        
        // Skip external packages
        if (!importName.startsWith(".") && !importName.startsWith("/"))
            return "";
        
        foreach (ref target; config.targets)
        {
            foreach (source; target.sources)
            {
                if (source.canFind(importName))
                    return target.name;
            }
        }
        
        return "";
    }
    
    private string resolveGoImport(string importName)
    {
        // Convert Go import to target
        
        foreach (ref target; config.targets)
        {
            if (target.name.canFind(importName))
                return target.name;
        }
        
        return "";
    }
    
    private string resolveRustImport(string importName)
    {
        // Convert Rust use statement to target
        
        auto parts = importName.split("::");
        
        foreach (ref target; config.targets)
        {
            if (parts.length > 0 && target.name.canFind(parts[0]))
                return target.name;
        }
        
        return "";
    }
    
    private string resolveCppImport(string importName)
    {
        // Convert C/C++ include to target
        
        foreach (ref target; config.targets)
        {
            foreach (source; target.sources)
            {
                if (source.endsWith(importName))
                    return target.name;
            }
        }
        
        return "";
    }
    
    private string resolveJavaImport(string importName)
    {
        // Convert Java import to target
        
        auto parts = importName.split(".");
        
        foreach (ref target; config.targets)
        {
            foreach (source; target.sources)
            {
                if (source.canFind(importName.replace(".", "/")))
                    return target.name;
            }
        }
        
        return "";
    }
    
    private string resolveDotNetImport(string importName)
    {
        // Convert C#/F# namespace/using to target
        // e.g., "MyApp.Services" -> "//src/Services:services"
        
        auto parts = importName.split(".");
        
        foreach (ref target; config.targets)
        {
            // Check if namespace matches target structure
            foreach (source; target.sources)
            {
                if (source.canFind(importName.replace(".", "/")) || 
                    source.canFind(importName.replace(".", "\\")))
                    return target.name;
            }
            
            // Check if target name matches namespace
            if (parts.length > 0 && target.name.canFind(parts[$ - 1]))
                return target.name;
        }
        
        return "";
    }
    
    private string resolveSwiftImport(string importName)
    {
        // Convert Swift import to target
        // e.g., "import MyModule" -> look for MyModule target
        
        foreach (ref target; config.targets)
        {
            if (target.name.canFind(importName))
                return target.name;
        }
        
        return "";
    }
    
    private string resolveRubyImport(string importName)
    {
        // Convert Ruby require to target
        // e.g., require 'my_lib' -> //lib:my_lib
        
        foreach (ref target; config.targets)
        {
            foreach (source; target.sources)
            {
                if (source.canFind(importName.replace("_", "/")) ||
                    source.baseName.stripExtension == importName)
                    return target.name;
            }
        }
        
        return "";
    }
    
    private string resolvePerlImport(string importName)
    {
        // Convert Perl use/require to target
        // e.g., use MyModule::Utils -> //lib/MyModule:Utils
        
        auto parts = importName.split("::");
        
        foreach (ref target; config.targets)
        {
            foreach (source; target.sources)
            {
                if (source.canFind(importName.replace("::", "/")))
                    return target.name;
            }
        }
        
        return "";
    }
    
    private string resolvePHPImport(string importName)
    {
        // Convert PHP namespace/use to target
        // e.g., App\Services\MyService -> //src/Services:myservice
        
        auto parts = importName.split("\\");
        
        foreach (ref target; config.targets)
        {
            foreach (source; target.sources)
            {
                if (source.canFind(importName.replace("\\", "/")))
                    return target.name;
            }
        }
        
        return "";
    }
    
    private string resolveElixirImport(string importName)
    {
        // Convert Elixir alias/import to target
        // e.g., MyApp.Services.Auth -> //lib/services:auth
        
        auto parts = importName.split(".");
        
        foreach (ref target; config.targets)
        {
            foreach (source; target.sources)
            {
                string snakeCase = importName.replace(".", "_").toLower;
                if (source.canFind(snakeCase))
                    return target.name;
            }
        }
        
        return "";
    }
    
    private string resolveGleamImport(string importName)
    {
        // Gleam imports use forward slashes: gleam/io, my_package/module
        // Convert to target reference
        
        foreach (ref target; config.targets)
        {
            foreach (source; target.sources)
            {
                string snakeCase = importName.replace("/", "_").toLower;
                if (source.canFind(snakeCase) || source.canFind(importName.replace("/", "/")))
                    return target.name;
            }
        }
        
        return "";
    }
    
    private string resolveLuaImport(string importName)
    {
        // Convert Lua require to target
        // e.g., require("my.module") -> //lua/my:module
        
        auto parts = importName.split(".");
        
        foreach (ref target; config.targets)
        {
            foreach (source; target.sources)
            {
                if (source.canFind(importName.replace(".", "/")))
                    return target.name;
            }
        }
        
        return "";
    }
    
    private string resolveRImport(string importName)
    {
        // Convert R library() call to target
        // e.g., library(mypackage) -> //R:mypackage
        
        foreach (ref target; config.targets)
        {
            if (target.name.canFind(importName))
                return target.name;
        }
        
        return "";
    }
    
    private string resolveOCamlImport(string importName)
    {
        // Convert OCaml open/module to target
        // e.g., open MyModule -> //src:MyModule
        
        foreach (ref target; config.targets)
        {
            foreach (source; target.sources)
            {
                if (source.baseName.stripExtension.toLower == importName.toLower)
                    return target.name;
            }
        }
        
        return "";
    }
    
    private string resolveHaskellImport(string importName)
    {
        // Convert Haskell import to target
        // e.g., import Data.Utils -> //src/Data:Utils
        
        auto parts = importName.split(".");
        
        foreach (ref target; config.targets)
        {
            foreach (source; target.sources)
            {
                if (source.canFind(importName.replace(".", "/")))
                    return target.name;
            }
        }
        
        return "";
    }
    
    private string resolveElmImport(string importName)
    {
        // Convert Elm import to target
        // e.g., import MyModule.Utils -> //src/MyModule:Utils
        
        auto parts = importName.split(".");
        
        foreach (ref target; config.targets)
        {
            foreach (source; target.sources)
            {
                if (source.canFind(importName.replace(".", "/")))
                    return target.name;
            }
        }
        
        return "";
    }
    
    /// Resolve typed Import to Dependency
    Dependency resolveTypedImport(Import imp, TargetLanguage language)
    {
        if (imp.isExternal)
            return Dependency("", DependencyKind.Direct, []); // External, not tracked
        
        auto targetName = resolveImport(imp.moduleName, language);
        
        if (targetName.empty)
            return Dependency("", DependencyKind.Implicit, [imp.moduleName]);
        
        return Dependency.direct(targetName, imp.moduleName);
    }
}

/// Fast import-to-target lookup index
class ImportIndex
{
    private string[string] moduleToTarget;
    private WorkspaceConfig config;
    
    this(WorkspaceConfig config)
    {
        this.config = config;
        buildIndex();
    }
    
    /// Build the index from workspace configuration
    private void buildIndex()
    {
        foreach (ref target; config.targets)
        {
            // Map each source file to this target
            foreach (source; target.sources)
            {
                auto normalized = source.buildNormalizedPath;
                moduleToTarget[normalized] = target.name;
                
                // Also index by base name without extension
                auto baseName = source.baseName.stripExtension;
                if (baseName !in moduleToTarget)
                    moduleToTarget[baseName] = target.name;
            }
        }
    }
    
    /// Look up target by module name (O(1) average case)
    string lookup(string moduleName) const
    {
        if (auto target = moduleName in moduleToTarget)
            return *target;
        
        // Try normalized path
        auto normalized = moduleName.buildNormalizedPath;
        if (auto target = normalized in moduleToTarget)
            return *target;
        
        return "";
    }
    
    /// Get all indexed modules
    string[] allModules() const
    {
        return moduleToTarget.keys;
    }
}

