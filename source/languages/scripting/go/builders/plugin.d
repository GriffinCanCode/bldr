module languages.scripting.go.builders.plugin;

import languages.scripting.go.builders.standard;
import languages.scripting.go.builders.base;
import languages.scripting.go.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache;

/// Plugin builder - builds Go plugins (deprecated but still supported)
class PluginBuilder : StandardBuilder
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
        structuredLog.info("building_go_plugin_note_go_plugins_are_d").emit();
        
        // Force plugin mode
        GoConfig mutableConfig = cast(GoConfig)config;
        mutableConfig.mode = GoBuildMode.Plugin;
        
        // Plugins don't work on all platforms
        version(Windows)
        {
            GoBuildResult result;
            result.error = "Go plugins are not supported on Windows";
            return result;
        }
        
        // Use standard builder with plugin mode
        return super.build(sources, mutableConfig, target, workspace);
    }
    
    override string name() const
    {
        return "plugin";
    }
    
    override bool supportsMode(GoBuildMode mode)
    {
        return mode == GoBuildMode.Plugin;
    }
}
