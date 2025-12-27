module languages.scripting.go.builders.cgo;

import std.array;
import std.range;
import languages.scripting.go.builders.standard;
import languages.scripting.go.builders.base;
import languages.scripting.go.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.logging;
import infrastructure.utils.process : isCommandAvailable;
import engine.caching.actions.action : ActionCache;

/// CGO builder - handles C interop compilation
class CGoBuilder : StandardBuilder
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
        // Ensure CGO is enabled
        GoConfig mutableConfig = cast(GoConfig)config;
        if (!mutableConfig.cgo.enabled)
        {
            structuredLog.info("enabling_cgo_for_c_interop_build").emit();
            mutableConfig.cgo.enabled = true;
        }
        
        // Validate C/C++ compiler availability if specified
        if (!mutableConfig.cgo.cc.empty)
        {
            if (!isCommandAvailable(mutableConfig.cgo.cc))
            {
                GoBuildResult result;
                result.error = "C compiler not found: " ~ mutableConfig.cgo.cc;
                return result;
            }
        }
        
        if (!mutableConfig.cgo.cxx.empty)
        {
            if (!isCommandAvailable(mutableConfig.cgo.cxx))
            {
                GoBuildResult result;
                result.error = "C++ compiler not found: " ~ mutableConfig.cgo.cxx;
                return result;
            }
        }
        
        structuredLog.info("building_with_cgo_enabled").emit();
        if (!mutableConfig.cgo.cflags.empty)
            structuredLog.debug_("cgo_cflags_").field("detail", "CGO_CFLAGS: " ~ mutableConfig.cgo.cflags.join(" ")).emit();
        if (!mutableConfig.cgo.ldflags.empty)
            structuredLog.debug_("cgo_ldflags_").field("detail", "CGO_LDFLAGS: " ~ mutableConfig.cgo.ldflags.join(" ")).emit();
        
        // Use standard builder with CGO configuration
        return super.build(sources, mutableConfig, target, workspace);
    }
    
    override string name() const
    {
        return "cgo";
    }
    
    override bool supportsMode(GoBuildMode mode)
    {
        return mode == GoBuildMode.CArchive ||
               mode == GoBuildMode.CShared ||
               mode == GoBuildMode.Executable ||
               mode == GoBuildMode.Library;
    }
    
}

