module languages.scripting.ruby.tooling.builders.gem;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.scripting.ruby.core.config;
import languages.scripting.ruby.tooling.builders.base;
import languages.scripting.ruby.tooling.info;
import languages.scripting.ruby.managers.rubygems;
import languages.base.base;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Gem builder for Ruby gems/libraries
class GemBuilder : Builder
{
    override BuildResult build(
        in string[] sources,
        in RubyConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        BuildResult result;
        
        // Find gemspec file
        string gemspecFile = config.gemBuild.gemspecFile;
        if (gemspecFile.empty)
        {
            auto gemspecs = GemspecUtil.findGemspecs(workspace.root);
            if (gemspecs.empty)
            {
                result.error = "No gemspec file found";
                return result;
            }
            gemspecFile = gemspecs[0];
            structuredLog.debug_("using_gemspec_").field("detail", "Using gemspec: " ~ gemspecFile).emit();
        }
        
        if (!exists(gemspecFile))
        {
            result.error = "Gemspec file not found: " ~ gemspecFile;
            return result;
        }
        
        // Validate syntax of source files
        if (!sources.empty)
        {
            string[] errors;
            if (!SyntaxChecker.check(sources, errors))
            {
                result.error = "Syntax errors:\n" ~ errors.join("\n");
                return result;
            }
        }
        
        // Build gem
        auto gemFile = buildGem(gemspecFile, config.gemBuild, workspace.root);
        if (gemFile.empty)
        {
            result.error = "Failed to build gem";
            return result;
        }
        
        // Move gem to output directory if specified
        if (!config.gemBuild.outputDir.empty)
        {
            auto targetPath = buildPath(config.gemBuild.outputDir, baseName(gemFile));
            
            if (!exists(config.gemBuild.outputDir))
            {
                try
                {
                    mkdirRecurse(config.gemBuild.outputDir);
                }
                catch (Exception e)
                {
                    structuredLog.warning("failed_to_create_output_directory_").field("detail", "Failed to create output directory: " ~ e.msg).emit();
                }
            }
            
            if (gemFile != targetPath)
            {
                try
                {
                    if (exists(targetPath))
                        remove(targetPath);
                    rename(gemFile, targetPath);
                    gemFile = targetPath;
                }
                catch (Exception e)
                {
                    structuredLog.warning("failed_to_move_gem_to_output_directory_").field("detail", "Failed to move gem to output directory: " ~ e.msg).emit();
                }
            }
        }
        
        result.success = true;
        result.outputs = [gemFile];
        result.outputHash = FastHash.hashStrings(sources);
        
        structuredLog.info("gem_built_successfully_").field("detail", "Gem built successfully: " ~ gemFile).emit();
        
        return result;
    }
    
    override bool isAvailable()
    {
        return RubyTools.isRubyAvailable();
    }
    
    override string name() const
    {
        return "Ruby Gem Builder";
    }
    
    private string buildGem(string gemspecFile, const GemBuildConfig config, string workDir)
    {
        string[] cmd = ["gem", "build", gemspecFile];
        
        // Sign gem if configured
        if (config.sign && !config.key.empty)
        {
            cmd ~= ["--sign", config.key];
        }
        
        structuredLog.info("building_gem_from_").field("detail", "Building gem from " ~ gemspecFile).emit();
        
        auto res = execute(cmd, null, Config.none, size_t.max, workDir);
        
        if (res.status != 0)
        {
            structuredLog.error("gem_build_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return "";
        }
        
        // Parse output to get gem filename
        // Output typically looks like: "Successfully built RubyGem\nName: gem-name\nVersion: 1.0.0\nFile: gem-name-1.0.0.gem"
        string gemFile;
        foreach (line; res.output.lineSplitter)
        {
            if (line.strip.startsWith("File:"))
            {
                gemFile = line.strip[5..$].strip;
                break;
            }
        }
        
        if (gemFile.empty)
        {
            // Fallback: look for .gem files in current directory
            try
            {
                foreach (entry; dirEntries(workDir, "*.gem", SpanMode.shallow))
                {
                    if (entry.isFile)
                    {
                        gemFile = entry.name;
                        break;
                    }
                }
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_find_gem_file_").field("detail", "Failed to find gem file: " ~ e.msg).emit();
            }
        }
        
        if (gemFile.empty)
        {
            structuredLog.error("could_not_determine_gem_filename").emit();
            return "";
        }
        
        // Make path absolute
        if (!isAbsolute(gemFile))
            gemFile = buildPath(workDir, gemFile);
        
        return gemFile;
    }
}


