module infrastructure.config.parsing.parser;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import infrastructure.config.analysis.semantic;
import infrastructure.config.workspace.workspace;
import infrastructure.config.schema.schema;
import infrastructure.config.caching.parse;
import infrastructure.analysis.detection.inference;
import infrastructure.utils.logging.logger;
import infrastructure.errors;
import infrastructure.errors.helpers;

/// High-level configuration parser
/// Wraps the unified parser and provides workspace-level parsing

class ConfigParser
{
    /// Parse entire workspace starting from root
    /// Returns Result with WorkspaceConfig
    static Result!(WorkspaceConfig, BuildError) parseWorkspace(
        in string root,
        in AggregationPolicy policy = AggregationPolicy.CollectAll) @system
    {
        WorkspaceConfig config;
        config.root = absolutePath(root);
        
        // Find all Builderfile files
        auto buildFiles = findBuildFiles(root);
        
        // Zero-config mode: infer targets if no Builderfiles found
        if (buildFiles.empty)
        {
            Logger.info("═══════════════════════════════════════════");
            Logger.info("  MODE: Zero-Config (No Builderfile found)");
            Logger.info("═══════════════════════════════════════════");
            Logger.info("Attempting automatic target inference...");
            
            try
            {
                auto inference = new TargetInference(root);
                config.targets = inference.inferTargets();
                
                if (config.targets.empty)
                {
                    auto error = createParseError(
                        root,
                        "No Builderfile found and no build targets could be automatically inferred",
                        ErrorCode.InvalidConfiguration
                    );
                    error.addSuggestion(ErrorSuggestion.command("Create a Builderfile", "bldr init"));
                    error.addSuggestion(ErrorSuggestion.docs("See zero-config mode", "docs/user-guides/examples.md"));
                    return Err!(WorkspaceConfig, BuildError)(error);
                }
                
                Logger.success("Zero-config mode: inferred " ~ 
                    config.targets.length.to!string ~ " target(s)");
            }
            catch (Exception e)
            {
                auto error = createParseError(
                    root,
                    "Failed to automatically infer build targets: " ~ e.msg,
                    ErrorCode.AnalysisFailed
                );
                error.addSuggestion(ErrorSuggestion.command("Create a Builderfile manually", "bldr init"));
                error.addSuggestion(ErrorSuggestion.command("Run with verbose output", "bldr build --verbose"));
                error.addContext(ErrorContext("auto-inference", e.msg));
                return Err!(WorkspaceConfig, BuildError)(error);
            }
        }
        else
        {
            Logger.info("═══════════════════════════════════════════");
            Logger.info("  MODE: Builderfile (" ~ buildFiles.length.to!string ~ " file(s) found)");
            Logger.info("═══════════════════════════════════════════");
            
            // Create parse cache
            auto cache = new ParseCache(true, buildPath(root, ".builder-cache/parse"));
            
            // Parse each Builderfile with error aggregation
            auto aggregated = aggregateMap(
                buildFiles,
                (string buildFile) => parseBuildFile(buildFile, root, cache),
                policy
            );
            
            // Log results
            if (aggregated.hasErrors)
            {
                Logger.warning(
                    "Failed to parse " ~ aggregated.errors.length.to!string ~
                    " Builderfile file(s)"
                );
                
                import infrastructure.errors.formatting.format : format;
                foreach (error; aggregated.errors)
                {
                    Logger.error(format(error));
                }
            }
            
            if (aggregated.hasSuccesses)
            {
                foreach (result; aggregated.successes)
                {
                    config.targets ~= result.targets;
                    config.repositories ~= result.repositories;
                }
                
                Logger.success(
                    "Successfully parsed " ~ config.targets.length.to!string ~
                    " target(s) from " ~ buildFiles.length.to!string ~ " Builderfile file(s)"
                );
                
                if (config.repositories.length > 0)
                {
                    Logger.info("Found " ~ config.repositories.length.to!string ~ " repository rule(s)");
                }
            }
            
            // Flush cache
            if (cache !is null)
                cache.close();
            
            if (policy == AggregationPolicy.FailFast && aggregated.hasErrors)
            {
                return Err!(WorkspaceConfig, BuildError)(aggregated.errors[0]);
            }
            
            if (aggregated.hasSuccesses || !aggregated.hasErrors)
            {
                // Continue to load workspace config
            }
            else if (aggregated.hasErrors)
            {
                return Err!(WorkspaceConfig, BuildError)(aggregated.errors[0]);
            }
        }
        
        // Load workspace config if exists
        string workspaceFile = buildPath(root, "Builderspace");
        if (exists(workspaceFile))
        {
            auto wsResult = parseWorkspaceFile(workspaceFile, config);
            if (wsResult.isErr)
            {
                auto error = wsResult.unwrapErr();
                Logger.error("Failed to parse Builderspace file");
                import infrastructure.errors.formatting.format : format;
                Logger.error(format(error));
                
                if (policy == AggregationPolicy.FailFast)
                {
                    return Err!(WorkspaceConfig, BuildError)(error);
                }
            }
        }
        
        return Ok!(WorkspaceConfig, BuildError)(config);
    }
    
    /// Find all Builderfile files in directory tree
    private static string[] findBuildFiles(string root)
    {
        string[] buildFiles;
        
        if (!exists(root) || !isDir(root))
            return buildFiles;
        
        foreach (entry; dirEntries(root, SpanMode.depth))
        {
            import infrastructure.utils.security.validation;
            if (!SecurityValidator.isPathWithinBase(entry.name, root))
                continue;
            
            if (entry.isFile && entry.name.baseName == "Builderfile")
                buildFiles ~= entry.name;
        }
        
        return buildFiles;
    }
    
    /// Parse a single Builderfile file
    private static Result!(ParseResult, BuildError) parseBuildFile(
        string path, 
        string root,
        ParseCache cache) @system
    {
        try
        {
            auto content = readText(path);
            return parseDSL(content, path, root);
        }
        catch (FileException e)
        {
            auto error = fileReadError(path, e.msg, "reading Builderfile");
            return Err!(ParseResult, BuildError)(error);
        }
        catch (Exception e)
        {
            auto error = parseErrorWithContext(path, 
                "Failed to parse Builderfile: " ~ e.msg, 0, 0, "parsing Builderfile file");
            return Err!(ParseResult, BuildError)(error);
        }
    }
    
    /// Parse workspace-level configuration
    private static Result!BuildError parseWorkspaceFile(string path, ref WorkspaceConfig config) @system
    {
        try
        {
            auto content = readText(path);
            // Future: Migrate to unified parser for workspace files
            // For now, just succeed
            return Result!BuildError.ok();
        }
        catch (FileException e)
        {
            auto error = fileReadError(path, e.msg, "reading Builderspace file");
            return Result!BuildError.err(error);
        }
        catch (Exception e)
        {
            auto error = parseErrorWithContext(path, 
                "Failed to parse Builderspace file: " ~ e.msg, 0, 0, "parsing Builderspace file");
            return Result!BuildError.err(error);
        }
    }
}
