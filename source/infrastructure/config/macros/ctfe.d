module infrastructure.config.macros.ctfe;

import std.traits;
import std.meta;
import std.array;
import std.algorithm;
import infrastructure.config.schema.schema;
import infrastructure.config.macros.api;
import infrastructure.errors;

/// Compile-Time Function Execution (CTFE) support
/// 
/// Enables D functions to be evaluated at compile-time for zero-runtime-overhead
/// target generation.

/// Mixin template for registering CTFE macros
mixin template RegisterMacro(alias Fn, string macroName)
{
    static assert(isCallable!Fn, "RegisterMacro: " ~ macroName ~ " must be a callable");
    
    // Generate registration code
    static this()
    {
        import infrastructure.config.macros.loader;
        MacroRegistry.instance.register(macroName, &Fn);
    }
}

/// Compile-time target generation helpers

/// Generate array of targets at compile time
template GenerateTargets(alias Fn, Items...)
{
    static foreach (item; Items)
    {
        enum GenerateTargets = Fn(item);
    }
}

/// Compile-time string interpolation
template Interpolate(string fmt, Args...)
{
    import std.format : format;
    enum Interpolate = format(fmt, Args);
}

/// Example CTFE macro functions

/// Generate multiple library targets
Target[] generateLibraries(string[] packages, string baseDir) pure @system
{
    return packages.map!(pkg =>
        library(
            pkg,
            [baseDir ~ "/" ~ pkg ~ "/**/*.d"],
            "d"
        )
    ).array;
}

/// Generate microservice targets
Target[] generateMicroservices(T)(T[] services)
    if (is(T == struct) || is(T == class))
{
    static assert(__traits(hasMember, T, "name"), "Service must have 'name' field");
    static assert(__traits(hasMember, T, "port"), "Service must have 'port' field");
    
    Target[] targets;
    foreach (service; services)
    {
        targets ~= executable(
            service.name,
            ["services/" ~ service.name ~ "/**/*.go"],
            "go"
        ).env([
            "PORT": service.port.to!string,
            "SERVICE": service.name
        ]);
    }
    return targets;
}

/// Generate test targets for each source file
Target[] generateTestTargets(string pattern, string testSuffix = "_test") @system
{
    import infrastructure.utils.files.glob : GlobMatcher;
    import std.path;
    import std.file : getcwd;
    
    auto sourceFiles = GlobMatcher.match([pattern], getcwd());
    
    return sourceFiles.map!(file =>
        test(
            file.baseName.stripExtension ~ testSuffix,
            [file]
        )
    ).array;
}

/// Platform matrix builder
struct PlatformMatrix
{
    string[] platforms;
    string[] architectures;
    string[string][string] configs;  // [platform][arch] = config
    
    Target[] generate(string name, string[] sources) const @system
    {
        Target[] targets;
        
        foreach (platform; platforms)
        {
            foreach (arch; architectures)
            {
                string targetName = name ~ "-" ~ platform ~ "-" ~ arch;
                auto target = executable(targetName, sources);
                
                // Add platform-specific configuration
                if (platform in configs && arch in configs[platform])
                {
                    // Apply config
                    target.flags ~= configs[platform][arch].split(" ");
                }
                
                targets ~= target;
            }
        }
        
        return targets;
    }
}

/// Code generation from templates

/// Template for generating similar targets
struct TargetTemplate
{
    TargetType type;
    string language;
    string sourcePattern;
    string[] commonFlags;
    string[string] commonEnv;
    
    Target instantiate(string name, string[string] overrides = null) const @system
    {
        import std.path;
        import std.string : replace;
        
        auto sources = sourcePattern.replace("{name}", name);
        
        // Create mutable copy of commonEnv
        string[string] envCopy;
        foreach (k, v; commonEnv)
            envCopy[k] = v;
        
        auto target = TargetBuilder.create(name)
            .type(type)
            .language(language)
            .sources([sources])
            .flags(commonFlags.dup)
            .env(envCopy)
            .build();
        
        // Apply overrides
        foreach (key, value; overrides)
        {
            // Apply override (simplified)
            if (key == "output")
                target.outputPath = value;
        }
        
        return target;
    }
    
    auto instantiateMany(string[] names) const @system
    {
        return names.map!(name => instantiate(name));
    }
}

/// Conditional compilation support

/// Generate targets based on compile-time conditions
Target[] conditionalTargets(Conditions...)() @system
{
    Target[] targets;
    
    static foreach (Cond; Conditions)
    {
        static if (Cond.predicate)
        {
            targets ~= Cond.target;
        }
    }
    
    return targets;
}

/// Condition template
template Condition(bool pred, alias targetFn)
{
    enum predicate = pred;
    alias target = targetFn;
}

/// Platform-specific conditions
enum isLinux = (){ version(linux) return true; else return false; }();
enum isDarwin = (){ version(OSX) return true; else return false; }();
enum isWindows = (){ version(Windows) return true; else return false; }();
enum isX86_64 = (){ version(X86_64) return true; else return false; }();
enum isARM64 = (){ version(AArch64) return true; else return false; }();

/// Type-safe target generation with compile-time validation

/// Validate target configuration at compile time
template ValidateTarget(Target target)
{
    static assert(target.name.length > 0, "Target must have a name");
    static assert(target.sources.length > 0, "Target must have sources");
    
    enum ValidateTarget = true;
}

/// Generate targets with compile-time validation
Target[] validatedTargets(Targets...)()
{
    static foreach (target; Targets)
    {
        static assert(ValidateTarget!target, "Invalid target configuration");
    }
    
    return [Targets];
}

/// Dependency graph generation

/// Generate dependency chain
Target[] generateDependencyChain(string[] names, string pattern) @system
{
    Target[] targets;
    string[] previousDeps;
    
    foreach (i, name; names)
    {
        auto target = library(name, [pattern.replace("{name}", name)]);
        target.deps = previousDeps.dup;
        targets ~= target;
        previousDeps = [":" ~ name];
    }
    
    return targets;
}

/// Generate dependency tree (fan-out)
Target[] generateDependencyTree(string root, string[][] layers, string pattern) @system
{
    Target[] targets;
    string[] previousLayer;
    
    foreach (layer; layers)
    {
        foreach (name; layer)
        {
            auto target = library(name, [pattern.replace("{name}", name)]);
            target.deps = previousLayer.dup;
            targets ~= target;
        }
        previousLayer = layer.map!(n => ":" ~ n).array;
    }
    
    // Root depends on last layer
    auto rootTarget = executable(root, [pattern.replace("{name}", root)]);
    rootTarget.deps = previousLayer;
    targets ~= rootTarget;
    
    return targets;
}

