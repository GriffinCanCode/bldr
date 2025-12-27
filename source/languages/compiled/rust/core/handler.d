module languages.compiled.rust.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import languages.base.base;
import languages.base.mixins;
import languages.compiled.rust.core.config;
import languages.compiled.rust.analysis.manifest;
import languages.compiled.rust.managers.toolchain;
import languages.compiled.rust.tooling.builders;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.analysis.targets.spec;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action;

/// Advanced Rust build handler with cargo, rustup, and toolchain support with action-level caching
class RustHandler : BaseLanguageHandler
{
    mixin CachingHandlerMixin!"rust";
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        structuredLog.debug_("building_rust_target_").field("detail", "Building Rust target: " ~ target.name).emit();
        
        // Parse Rust configuration
        RustConfig rustConfig = parseRustConfig(target);
        
        // Check and install toolchain if needed
        if (!rustConfig.toolchain.empty && rustConfig.installToolchain)
        {
            if (!ensureToolchain(rustConfig.toolchain))
            {
                result.error = "Failed to ensure toolchain: " ~ rustConfig.toolchain;
                return result;
            }
        }
        
        // Check and install target if needed
        if (!rustConfig.target.empty)
        {
            if (!ensureTarget(rustConfig.target, rustConfig.toolchain))
            {
                structuredLog.warning("target_triple_may_not_be_installed_").field("detail", "Target triple may not be installed: " ~ rustConfig.target).emit();
            }
        }
        
        // Run clippy if requested
        if (rustConfig.clippy)
        {
            auto clippyResult = runClippy(target, rustConfig, config);
            if (clippyResult.hadClippyIssues)
            {
                structuredLog.warning("clippy_found_issues").emit();
                foreach (issue; clippyResult.clippyIssues)
                {
                    structuredLog.warning("__").field("detail", "  " ~ issue).emit();
                }
            }
        }
        
        // Run rustfmt if requested
        if (rustConfig.fmt)
        {
            runRustfmt(target, rustConfig);
        }
        
        // Build based on target type
        final switch (target.type)
        {
            case TargetType.Executable:
                result = buildExecutable(target, config, rustConfig);
                break;
            case TargetType.Library:
                result = buildLibrary(target, config, rustConfig);
                break;
            case TargetType.Test:
                result = runTests(target, config, rustConfig);
                break;
            case TargetType.Custom:
            case TargetType.Shell:
                result = buildCustom(target, config, rustConfig);
                break;
        }
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        RustConfig rustConfig = parseRustConfig(target);
        
        string[] outputs;
        
        if (!target.outputPath.empty)
        {
            outputs ~= buildPath(config.options.outputDir, target.outputPath);
        }
        else
        {
            auto name = target.name.split(":")[$ - 1];
            outputs ~= buildPath(config.options.outputDir, name);
        }
        
        return outputs;
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        auto spec = getLanguageSpec(TargetLanguage.Rust);
        if (spec is null)
            return [];
        
        Import[] allImports;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            try
            {
                auto content = readText(source);
                auto imports = spec.scanImports(source, content);
                allImports ~= imports;
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_analyze_imports_in_").field("detail", "Failed to analyze imports in " ~ source).emit();
            }
        }
        
        return allImports;
    }
    
    private LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, RustConfig rustConfig)
    {
        LanguageBuildResult result;
        
        // Set crate type to binary
        if (rustConfig.crateType == CrateType.Lib)
            rustConfig.crateType = CrateType.Bin;
        
        // Auto-detect entry point if not specified
        if (rustConfig.entry.empty && !target.sources.empty)
        {
            rustConfig.entry = target.sources[0];
        }
        
        // Build with selected compiler
        return compileTarget(target, config, rustConfig);
    }
    
    private LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, RustConfig rustConfig)
    {
        LanguageBuildResult result;
        
        // Set crate type to library if not specified
        if (rustConfig.crateType == CrateType.Bin)
            rustConfig.crateType = CrateType.Lib;
        
        // Auto-detect entry point
        if (rustConfig.entry.empty && !target.sources.empty)
        {
            // Look for lib.rs first
            foreach (source; target.sources)
            {
                if (baseName(source) == "lib.rs")
                {
                    rustConfig.entry = source;
                    break;
                }
            }
            
            // Fallback to first source
            if (rustConfig.entry.empty)
                rustConfig.entry = target.sources[0];
        }
        
        return compileTarget(target, config, rustConfig);
    }
    
    private LanguageBuildResult runTests(in Target target, in WorkspaceConfig config, RustConfig rustConfig)
    {
        LanguageBuildResult result;
        
        // Set mode to test
        rustConfig.mode = RustBuildMode.Test;
        
        // Use test profile
        if (rustConfig.profile == RustProfile.Release)
            rustConfig.profile = RustProfile.Test;
        
        return compileTarget(target, config, rustConfig);
    }
    
    private LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, RustConfig rustConfig)
    {
        LanguageBuildResult result;
        
        rustConfig.mode = RustBuildMode.Custom;
        
        return compileTarget(target, config, rustConfig);
    }
    
    private LanguageBuildResult compileTarget(in Target target, in WorkspaceConfig config, RustConfig rustConfig)
    {
        LanguageBuildResult result;
        
        // Create builder, pass actionCache for per-build-step caching
        auto builder = RustBuilderFactory.create(rustConfig.compiler, rustConfig, actionCache);
        
        if (!builder.isAvailable())
        {
            result.error = "Rust compiler '" ~ builder.name() ~ "' is not available. " ~
                          "Install Rust from https://rustup.rs/";
            return result;
        }
        
        structuredLog.debug_("using_rust_builder_").field("detail", "Using Rust builder: " ~ builder.name() ~ " (" ~ builder.getVersion() ~ ")").emit();
        
        // Compile
        auto compileResult = builder.build(target.sources, rustConfig, target, config);
        
        if (!compileResult.success)
        {
            result.error = compileResult.error;
            return result;
        }
        
        // Report warnings
        if (compileResult.hadWarnings)
        {
            structuredLog.warning("compilation_warnings").emit();
            foreach (warn; compileResult.warnings)
            {
                structuredLog.warning("__").field("detail", "  " ~ warn).emit();
            }
        }
        
        result.success = true;
        result.outputs = compileResult.outputs ~ compileResult.artifacts;
        result.outputHash = compileResult.outputHash;
        
        return result;
    }
    
    private RustConfig parseRustConfig(in Target target)
    {
        RustConfig config;
        
        // Try language-specific keys
        string configKey = "";
        if ("rust" in target.langConfig)
            configKey = "rust";
        else if ("rustConfig" in target.langConfig)
            configKey = "rustConfig";
        
        if (!configKey.empty)
        {
            try
            {
                auto json = parseJSON(target.langConfig[configKey]);
                config = RustConfig.fromJSON(json);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_rust_config_using_defaul").field("detail", "Failed to parse Rust config, using defaults: " ~ e.msg).emit();
            }
        }
        
        // Auto-detect Cargo.toml if not specified
        if (config.manifest.empty)
        {
            config.manifest = CargoParser.findManifest(target.sources.dup);
            if (!config.manifest.empty)
            {
                structuredLog.debug_("found_cargotoml_").field("detail", "Found Cargo.toml: " ~ config.manifest).emit();
            }
        }
        
        // Auto-detect entry point if not specified
        if (config.entry.empty && !target.sources.empty)
        {
            config.entry = target.sources[0];
        }
        
        // Apply target flags to rustc flags
        if (!target.flags.empty)
        {
            config.rustcFlags ~= target.flags;
        }
        
        return config;
    }
    
    private bool ensureToolchain(string toolchain)
    {
        if (!Rustup.isAvailable())
        {
            structuredLog.warning("rustup_not_available_cannot_ensure_toolc").emit();
            return false;
        }
        
        auto toolchains = Rustup.listToolchains();
        
        foreach (tc; toolchains)
        {
            if (tc.name == toolchain && tc.isInstalled)
            {
                structuredLog.debug_("toolchain_already_installed_").field("detail", "Toolchain already installed: " ~ toolchain).emit();
                return true;
            }
        }
        
        // Install toolchain
        return Rustup.installToolchain(toolchain);
    }
    
    private bool ensureTarget(string target, string toolchain)
    {
        if (!Rustup.isAvailable())
        {
            structuredLog.warning("rustup_not_available_cannot_ensure_targe").emit();
            return false;
        }
        
        auto targets = Rustup.listTargets(toolchain);
        
        foreach (t; targets)
        {
            if (t.name == target && t.isInstalled)
            {
                structuredLog.debug_("target_already_installed_").field("detail", "Target already installed: " ~ target).emit();
                return true;
            }
        }
        
        // Install target
        return Rustup.installTarget(target, toolchain);
    }
    
    private RustCompileResult runClippy(in Target target, RustConfig config, in WorkspaceConfig workspace)
    {
        RustCompileResult result;
        
        if (!Clippy.isAvailable())
        {
            structuredLog.warning("clippy_not_available_skipping").emit();
            result.success = true;
            return result;
        }
        
        structuredLog.info("running_clippy").emit();
        
        string manifestPath = config.manifest.empty
            ? CargoParser.findManifest(target.sources.dup)
            : config.manifest;
        
        if (manifestPath.empty)
        {
            structuredLog.warning("no_cargotoml_found_skipping_clippy").emit();
            result.success = true;
            return result;
        }
        
        string projectDir = dirName(manifestPath);
        
        auto res = Clippy.run(projectDir, config.clippyFlags);
        
        if (res.status != 0)
        {
            result.hadClippyIssues = true;
            
            // Parse clippy output
            foreach (line; res.output.split("\n"))
            {
                if (line.canFind("warning:") || line.canFind("error:"))
                {
                    result.clippyIssues ~= line;
                }
            }
        }
        
        result.success = true;
        return result;
    }
    
    private void runRustfmt(in Target target, RustConfig config)
    {
        if (!Rustfmt.isAvailable())
        {
            structuredLog.warning("rustfmt_not_available_skipping").emit();
            return;
        }
        
        structuredLog.info("running_rustfmt").emit();
        
        string manifestPath = config.manifest.empty
            ? CargoParser.findManifest(target.sources.dup)
            : config.manifest;
        
        if (manifestPath.empty)
        {
            structuredLog.warning("no_cargotoml_found_skipping_rustfmt").emit();
            return;
        }
        
        string projectDir = dirName(manifestPath);
        
        auto res = Rustfmt.format(projectDir);
        
        if (res.status != 0)
        {
            structuredLog.warning("rustfmt_failed_").field("detail", "rustfmt failed: " ~ res.output).emit();
        }
        else
        {
            structuredLog.info("code_formatted_successfully").emit();
        }
    }
}


