module languages.scripting.ruby.tooling.builders.rails;

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
import languages.base.base;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Rails builder for Ruby on Rails applications
class RailsBuilder : Builder
{
    override BuildResult build(
        in string[] sources,
        in RubyConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        BuildResult result;
        
        // Verify Rails project structure
        if (!ProjectDetector.isRailsProject(workspace.root))
        {
            result.error = "Not a valid Rails project";
            return result;
        }
        
        // Check Rails availability
        if (!isRailsAvailable(workspace.root))
        {
            result.error = "Rails not available (run: bundle install)";
            return result;
        }
        
        // Set Rails environment
        string[string] env;
        foreach (key, value; environment.toAA())
            env[key] = value;
        
        env["RAILS_ENV"] = config.rails.environment;
        
        // Add custom environment variables
        foreach (key, value; config.env)
            env[key] = value;
        
        // Run database migrations if configured
        if (config.rails.runMigrations)
        {
            structuredLog.info("running_database_migrations").emit();
            if (!runMigrations(workspace.root, env, config.rails.commandPrefix))
            {
                result.toolWarnings ~= "Database migrations failed";
            }
        }
        
        // Seed database if configured
        if (config.rails.seedDatabase)
        {
            structuredLog.info("seeding_database").emit();
            if (!seedDatabase(workspace.root, env, config.rails.commandPrefix))
            {
                result.toolWarnings ~= "Database seeding failed";
            }
        }
        
        // Precompile assets if configured
        if (config.rails.precompileAssets)
        {
            structuredLog.info("precompiling_assets").emit();
            if (!precompileAssets(workspace.root, env, config.rails.commandPrefix))
            {
                result.error = "Asset precompilation failed";
                return result;
            }
        }
        
        // Validate Rails application
        structuredLog.info("validating_rails_application").emit();
        if (!validateRailsApp(workspace.root, env, config.rails.commandPrefix))
        {
            result.error = "Rails application validation failed";
            return result;
        }
        
        result.success = true;
        result.outputs = [workspace.root]; // Rails apps don't produce a single output
        
        if (!sources.empty)
            result.outputHash = FastHash.hashStrings(sources);
        
        return result;
    }
    
    override bool isAvailable()
    {
        // Rails requires Ruby and bundler
        return RubyTools.isRubyAvailable() && RubyTools.isBundlerAvailable();
    }
    
    override string name() const
    {
        return "Ruby on Rails Builder";
    }
    
    private bool isRailsAvailable(string projectRoot)
    {
        // Check if rails command is available via bundler
        auto res = execute(
            ["bundle", "exec", "rails", "--version"],
            null,
            Config.none,
            size_t.max,
            projectRoot
        );
        return res.status == 0;
    }
    
    private bool runMigrations(string projectRoot, string[string] env, string commandPrefix)
    {
        auto cmd = buildRailsCommand(commandPrefix, ["db:migrate"]);
        
        auto res = execute(cmd, env, Config.none, size_t.max, projectRoot);
        
        if (res.status != 0)
        {
            structuredLog.error("migration_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    private bool seedDatabase(string projectRoot, string[string] env, string commandPrefix)
    {
        auto cmd = buildRailsCommand(commandPrefix, ["db:seed"]);
        
        auto res = execute(cmd, env, Config.none, size_t.max, projectRoot);
        
        if (res.status != 0)
        {
            structuredLog.error("database_seeding_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    private bool precompileAssets(string projectRoot, string[string] env, string commandPrefix)
    {
        auto cmd = buildRailsCommand(commandPrefix, ["assets:precompile"]);
        
        auto res = execute(cmd, env, Config.none, size_t.max, projectRoot);
        
        if (res.status != 0)
        {
            structuredLog.error("asset_precompilation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        structuredLog.info("assets_precompiled_successfully").emit();
        return true;
    }
    
    private bool validateRailsApp(string projectRoot, string[string] env, string commandPrefix)
    {
        // Run rails runner with a simple validation
        auto cmd = buildRailsCommand(commandPrefix, ["runner", "Rails.application.eager_load!"]);
        
        auto res = execute(cmd, env, Config.none, size_t.max, projectRoot);
        
        if (res.status != 0)
        {
            structuredLog.error("rails_validation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
    
    private string[] buildRailsCommand(string commandPrefix, string[] args)
    {
        // Handle different Rails command formats
        // bin/rails, bundle exec rails, rails
        
        if (commandPrefix.canFind("bundle"))
        {
            return ["bundle", "exec", "rails"] ~ args;
        }
        else if (commandPrefix.canFind("/"))
        {
            // Specific path like bin/rails
            return [commandPrefix] ~ args;
        }
        else
        {
            return ["rails"] ~ args;
        }
    }
}


