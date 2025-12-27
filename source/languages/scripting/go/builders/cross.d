module languages.scripting.go.builders.cross;

import std.process;
import std.algorithm;
import std.array;
import languages.scripting.go.builders.standard;
import languages.scripting.go.builders.base;
import languages.scripting.go.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache;

/// Cross-compilation builder - handles GOOS/GOARCH compilation
class CrossBuilder : StandardBuilder
{
    this(ActionCache actionCache = null)
    {
        super(actionCache);
    }
    
    override GoBuildResult build(
        in string[] sources,
        in GoConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        if (!config.cross.goos.empty)
            structuredLog.info("crosscompiling_for_goos").field("detail", "Cross-compiling for GOOS=" ~ config.cross.goos).emit();
        if (!config.cross.goarch.empty)
            structuredLog.info("crosscompiling_for_goarch").field("detail", "Cross-compiling for GOARCH=" ~ config.cross.goarch).emit();
        
        // Validate target combination
        if (!isValidTarget(config.cross))
        {
            GoBuildResult result;
            result.error = "Invalid cross-compilation target: " ~ 
                          config.cross.goos ~ "/" ~ config.cross.goarch;
            return result;
        }
        
        // CGO is typically disabled for cross-compilation
        if (config.cgo.enabled)
        {
            structuredLog.warning("cgo_is_enabled_for_crosscompilation_").field("detail", "CGO is enabled for cross-compilation. " ~
                          "This requires appropriate C cross-compiler setup.").emit();
        }
        else
        {
            // Explicitly disable CGO for cross-compilation
            GoConfig mutableConfig = cast(GoConfig)config;
            mutableConfig.cgo.enabled = false;
            return super.build(sources, mutableConfig, target, workspace);
        }
        
        // Use standard builder with cross-compilation environment
        return super.build(sources, config, target, workspace);
    }
    
    override string name() const
    {
        return "cross";
    }
    
    override bool supportsMode(GoBuildMode mode)
    {
        return mode == GoBuildMode.Executable ||
               mode == GoBuildMode.Library;
    }
    
    /// Check if GOOS/GOARCH combination is valid
    private bool isValidTarget(CrossTarget cross)
    {
        // Common valid combinations (not exhaustive)
        static immutable validCombinations = [
            "linux/amd64", "linux/386", "linux/arm", "linux/arm64",
            "darwin/amd64", "darwin/arm64",
            "windows/amd64", "windows/386", "windows/arm", "windows/arm64",
            "freebsd/amd64", "freebsd/386", "freebsd/arm",
            "netbsd/amd64", "netbsd/386", "netbsd/arm",
            "openbsd/amd64", "openbsd/386", "openbsd/arm", "openbsd/arm64",
            "dragonfly/amd64",
            "plan9/amd64", "plan9/386", "plan9/arm",
            "solaris/amd64",
            "android/amd64", "android/386", "android/arm", "android/arm64",
            "ios/amd64", "ios/arm64",
            "js/wasm",
            "aix/ppc64",
        ];
        
        if (cross.goos.empty || cross.goarch.empty)
            return true; // No cross-compilation
        
        auto combo = cross.goos ~ "/" ~ cross.goarch;
        return validCombinations.canFind(combo);
    }
}

