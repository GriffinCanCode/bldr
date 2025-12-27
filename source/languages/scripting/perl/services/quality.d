module languages.scripting.perl.services.quality;

import languages.scripting.perl.core.config;
import infrastructure.config.schema.schema : LanguageBuildResult;
import engine.caching.actions.action;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import std.range : empty;
import std.array : join;

/// Code quality service interface
interface IPerlQualityService
{
    /// Check syntax of Perl files
    bool checkSyntax(in string[] sources, in PerlConfig config, 
                    ref string[] errors, ActionCache cache);
    
    /// Format code with perltidy
    void formatCode(in string[] sources, in PerlConfig config);
    
    /// Lint with Perl::Critic
    LanguageBuildResult lintCode(in string[] sources, in PerlConfig config, 
                                 ActionCache cache);
}

/// Concrete Perl quality service
final class PerlQualityService : IPerlQualityService
{
    bool checkSyntax(
        in string[] sources,
        in PerlConfig config,
        ref string[] errors,
        ActionCache cache
    ) @trusted
    {
        import std.process : execute;
        import std.file : exists, isFile;
        import std.path : baseName;
        import std.conv : to;
        
        string perlCmd = config.perlVersion.interpreterPath.empty 
            ? "perl" 
            : config.perlVersion.interpreterPath;
        
        bool allValid = true;
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            // Create cache metadata
            string[string] metadata;
            metadata["interpreter"] = perlCmd;
            metadata["warnings"] = config.warnings.to!string;
            metadata["includeDirs"] = config.includeDirs.join(",");
            
            // Create action ID
            ActionId actionId;
            actionId.targetId = "syntax_check";
            actionId.type = ActionType.Compile;
            actionId.subId = baseName(source);
            actionId.inputHash = FastHash.hashFile(source);
            
            // Check cache
            if (cache.isCached(actionId, [source], metadata))
            {
                structuredLog.debug_("__cached_syntax_check_").field("detail", "  [Cached] Syntax check: " ~ source).emit();
                continue;
            }
            
            // Build syntax check command
            string[] cmd = [perlCmd, "-c"];
            
            if (config.warnings)
                cmd ~= "-w";
            
            foreach (incDir; config.includeDirs)
            {
                cmd ~= ["-I", incDir];
            }
            
            cmd ~= source;
            
            // Execute check
            bool success = false;
            try
            {
                auto res = execute(cmd);
                success = (res.status == 0);
                
                if (!success)
                {
                    errors ~= source ~ ": " ~ res.output;
                    allValid = false;
                }
            }
            catch (Exception e)
            {
                errors ~= source ~ ": " ~ e.msg;
                allValid = false;
            }
            
            // Update cache
            cache.update(actionId, [source], [], metadata, success);
        }
        
        return allValid;
    }
    
    void formatCode(in string[] sources, in PerlConfig config) @trusted
    {
        import std.process : execute;
        import std.file : exists, isFile;
        
        // Check if perltidy is available
        try
        {
            auto checkResult = execute(["perltidy", "--version"]);
            if (checkResult.status != 0)
                return;
        }
        catch (Exception e)
        {
            return;
        }
        
        structuredLog.info("formatting_perl_code_with_perltidy").emit();
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            string[] cmd = ["perltidy", "-b"];
            
            if (exists(config.format.perltidyrc))
                cmd ~= ["-pro=" ~ config.format.perltidyrc];
            
            cmd ~= source;
            
            try
            {
                execute(cmd);
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_format_").field("detail", "Failed to format " ~ source ~ ": " ~ e.msg).emit();
            }
        }
    }
    
    LanguageBuildResult lintCode(
        in string[] sources,
        in PerlConfig config,
        ActionCache cache
    ) @trusted
    {
        import std.process : execute;
        import std.file : exists;
        import std.conv : to;
        
        LanguageBuildResult result;
        
        // Check if perlcritic is available
        try
        {
            auto checkResult = execute(["perlcritic", "--version"]);
            if (checkResult.status != 0)
            {
                result.success = true;
                return result;
            }
        }
        catch (Exception e)
        {
            result.success = true;
            return result;
        }
        
        structuredLog.info("linting_perl_code_with_perlcritic").emit();
        
        // Build cache metadata
        string[string] metadata;
        metadata["severity"] = config.format.critic.severity.to!string;
        metadata["verbose"] = config.format.critic.verbose.to!string;
        metadata["theme"] = config.format.critic.theme;
        metadata["include"] = config.format.critic.include.join(",");
        metadata["exclude"] = config.format.critic.exclude.join(",");
        
        if (exists(config.format.perlcriticrc))
            metadata["profile"] = FastHash.hashFile(config.format.perlcriticrc);
        
        // Create action ID
        ActionId actionId;
        actionId.targetId = "perlcritic";
        actionId.type = ActionType.Custom;
        actionId.subId = "analysis";
        actionId.inputHash = FastHash.hashStrings(sources);
        
        // Check cache
        if (cache.isCached(actionId, sources, metadata))
        {
            structuredLog.info("__cached_perlcritic_analysis").emit();
            result.success = true;
            return result;
        }
        
        // Build critic command
        string[] cmd = ["perlcritic"];
        
        cmd ~= ["--severity", config.format.critic.severity.to!string];
        
        if (exists(config.format.perlcriticrc))
            cmd ~= ["--profile", config.format.perlcriticrc];
        
        if (config.format.critic.verbose)
            cmd ~= "--verbose";
        
        if (!config.format.critic.theme.empty)
            cmd ~= ["--theme", config.format.critic.theme];
        
        foreach (policy; config.format.critic.include)
            cmd ~= ["--include", policy];
        
        foreach (policy; config.format.critic.exclude)
            cmd ~= ["--exclude", policy];
        
        cmd ~= sources;
        
        // Execute linting
        bool success = false;
        try
        {
            auto res = execute(cmd);
            success = (res.status == 0);
            
            if (!success)
            {
                result.error = res.output;
            }
            else
            {
                result.success = true;
            }
        }
        catch (Exception e)
        {
            result.error = e.msg;
        }
        
        // Update cache
        cache.update(actionId, sources, [], metadata, success);
        
        return result;
    }
}

