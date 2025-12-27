module languages.compiled.rust.core.handler;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.json;
import std.string;
import languages.compiled.base;
import languages.compiled.rust.core.config;
import languages.compiled.rust.analysis.manifest;
import languages.compiled.rust.managers.toolchain;
import languages.compiled.rust.tooling.builders;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action;

/// Advanced Rust build handler with cargo, rustup, and toolchain support
class RustHandler : BaseCompiledLanguageHandler
{
    private RustConfig _config;
    
    this() { super(null); }
    
    // ===== Required Overrides =====
    
    override protected string languageId() const pure nothrow => "rust";
    
    override protected TargetLanguage languageType() const pure nothrow => TargetLanguage.Rust;
    
    override protected string[] configKeys() const pure nothrow => ["rust", "rustConfig"];
    
    override protected string toolchainNotFoundError() const pure nothrow =>
        "Rust compiler not available. Install from https://rustup.rs/";
    
    override protected string detectToolchain(in Target target, in WorkspaceConfig config) @system
    {
        import infrastructure.toolchain.detection.detector : ExecutableDetector;
        
        // Parse config to check for toolchain preference
        _config = parseRustConfig(target);
        
        // Check if rustup is available
        auto rustup = ExecutableDetector.findInPath("rustup");
        if (!rustup.empty)
        {
            // If specific toolchain requested, ensure it's installed
            if (!_config.toolchain.empty && _config.installToolchain)
            {
                if (!ensureToolchain(_config.toolchain))
                    structuredLog.warning("failed_to_install_toolchain_").field("detail", "Failed to ensure toolchain: " ~ _config.toolchain).emit();
            }
            
            // If specific target requested, ensure it's installed
            if (!_config.target.empty)
            {
                if (!ensureTarget(_config.target, _config.toolchain))
                    structuredLog.warning("target_may_not_be_installed_").field("detail", "Target may not be installed: " ~ _config.target).emit();
            }
        }
        
        // Prefer cargo if Cargo.toml exists
        auto cargo = ExecutableDetector.findInPath("cargo");
        if (!cargo.empty && !_config.manifest.empty)
            return cargo;
        
        // Fallback to rustc
        return ExecutableDetector.findInPath("rustc");
    }
    
    // ===== Build Methods =====
    
    override protected LanguageBuildResult buildExecutable(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        if (_config.crateType == CrateType.Lib)
            _config.crateType = CrateType.Bin;
        
        if (_config.entry.empty && !target.sources.empty)
            _config.entry = target.sources[0];
        
        return compileTarget(target, config);
    }
    
    override protected LanguageBuildResult buildLibrary(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        if (_config.crateType == CrateType.Bin)
            _config.crateType = CrateType.Lib;
        
        if (_config.entry.empty && !target.sources.empty)
        {
            // Look for lib.rs first
            foreach (source; target.sources)
            {
                if (baseName(source) == "lib.rs")
                {
                    _config.entry = source;
                    break;
                }
            }
            if (_config.entry.empty)
                _config.entry = target.sources[0];
        }
        
        return compileTarget(target, config);
    }
    
    override protected LanguageBuildResult buildAndRunTests(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        _config.mode = RustBuildMode.Test;
        if (_config.profile == RustProfile.Release)
            _config.profile = RustProfile.Test;
        
        return compileTarget(target, config);
    }
    
    override protected LanguageBuildResult buildCustom(in Target target, in WorkspaceConfig config, string toolPath) @system
    {
        _config.mode = RustBuildMode.Custom;
        return compileTarget(target, config);
    }
    
    // ===== Tooling =====
    
    override protected bool shouldFormat(in Target target) const @system => _config.fmt;
    override protected bool shouldLint(in Target target) const @system => _config.clippy;
    
    override protected CompiledLanguageResult runFormatter(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        result.success = true;
        
        if (!Rustfmt.isAvailable())
        {
            structuredLog.warning("rustfmt_not_available_skipping").emit();
            return result;
        }
        
        structuredLog.info("running_rustfmt").emit();
        
        string manifestPath = _config.manifest.empty
            ? CargoParser.findManifest(target.sources.dup)
            : _config.manifest;
        
        if (manifestPath.empty)
        {
            structuredLog.warning("no_cargotoml_found_skipping_rustfmt").emit();
            return result;
        }
        
        auto res = Rustfmt.format(dirName(manifestPath));
        if (res.status != 0)
        {
            structuredLog.warning("rustfmt_failed_").field("detail", "rustfmt failed: " ~ res.output).emit();
            result.hadWarnings = true;
            result.warnings = [res.output];
        }
        else
            structuredLog.info("code_formatted_successfully").emit();
        
        return result;
    }
    
    override protected CompiledLanguageResult runLinter(in Target target, in WorkspaceConfig config) @system
    {
        CompiledLanguageResult result;
        result.success = true;
        
        if (!Clippy.isAvailable())
        {
            structuredLog.warning("clippy_not_available_skipping").emit();
            return result;
        }
        
        structuredLog.info("running_clippy").emit();
        
        string manifestPath = _config.manifest.empty
            ? CargoParser.findManifest(target.sources.dup)
            : _config.manifest;
        
        if (manifestPath.empty)
        {
            structuredLog.warning("no_cargotoml_found_skipping_clippy").emit();
            return result;
        }
        
        auto res = Clippy.run(dirName(manifestPath), _config.clippyFlags);
        if (res.status != 0)
        {
            result.hadLintIssues = true;
            foreach (line; res.output.split("\n"))
            {
                if (line.canFind("warning:") || line.canFind("error:"))
                    result.lintIssues ~= line;
            }
        }
        
        return result;
    }
    
    // ===== Private Implementation =====
    
    private LanguageBuildResult compileTarget(in Target target, in WorkspaceConfig config) @system
    {
        auto builder = RustBuilderFactory.create(_config.compiler, _config, actionCache);
        
        if (!builder.isAvailable())
            return errorResult("Rust compiler '" ~ builder.name() ~ "' is not available. Install from https://rustup.rs/");
        
        structuredLog.debug_("using_rust_builder_").field("detail", "Using Rust builder: " ~ builder.name() ~ " (" ~ builder.getVersion() ~ ")").emit();
        
        auto compileResult = builder.build(target.sources, _config, target, config);
        
        if (!compileResult.success)
            return errorResult(compileResult.error);
        
        if (compileResult.hadWarnings)
            reportWarnings(compileResult.warnings);
        
        return successResult(compileResult.outputs, compileResult.artifacts, compileResult.outputHash);
    }
    
    private RustConfig parseRustConfig(in Target target) @system
    {
        RustConfig config;
        
        auto json = parseTargetConfig(target);
        if (json != JSONValue.init)
        {
            try { config = RustConfig.fromJSON(json); }
            catch (Exception e)
                structuredLog.warning("failed_to_parse_rust_config_").field("detail", "Using defaults: " ~ e.msg).emit();
        }
        
        // Auto-detect Cargo.toml
        if (config.manifest.empty)
        {
            config.manifest = CargoParser.findManifest(target.sources.dup);
            if (!config.manifest.empty)
                structuredLog.debug_("found_cargotoml_").field("detail", "Found Cargo.toml: " ~ config.manifest).emit();
        }
        
        // Auto-detect entry point
        if (config.entry.empty && !target.sources.empty)
            config.entry = target.sources[0];
        
        // Apply target flags
        if (!target.flags.empty)
            config.rustcFlags ~= target.flags;
        
        return config;
    }
    
    private bool ensureToolchain(string toolchain) @system
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
                structuredLog.debug_("toolchain_already_installed_").field("detail", "Toolchain installed: " ~ toolchain).emit();
                return true;
            }
        }
        
        return Rustup.installToolchain(toolchain);
    }
    
    private bool ensureTarget(string target, string toolchain) @system
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
                structuredLog.debug_("target_already_installed_").field("detail", "Target installed: " ~ target).emit();
                return true;
            }
        }
        
        return Rustup.installTarget(target, toolchain);
    }
}
