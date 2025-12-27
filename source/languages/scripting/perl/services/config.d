module languages.scripting.perl.services.config;

import languages.scripting.perl.core.config;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.logging;
import std.json : JSONValue, parseJSON;
import std.range : empty;

/// Configuration service interface
interface IPerlConfigService
{
    /// Parse and enhance Perl configuration from target
    PerlConfig parse(in Target target, in WorkspaceConfig workspace);
    
    /// Validate Perl interpreter availability
    bool validateInterpreter(in PerlConfig config);
}

/// Concrete Perl configuration service
final class PerlConfigService : IPerlConfigService
{
    PerlConfig parse(in Target target, in WorkspaceConfig workspace) @trusted
    {
        import std.json : parseJSON, JSONValue, JSONException;
        import std.array : empty;
        import std.path : buildPath;
        import std.file : exists;
        import std.conv : to;
        
        // Parse base config from target
        PerlConfig config;
        
        // Check if target has Perl-specific configuration
        if ("perl" in target.langConfig)
        {
            try
            {
                auto jsonStr = target.langConfig["perl"];
                if (!jsonStr.empty)
                {
                    auto json = parseJSON(jsonStr);
                    config = parsePerlConfig(json);
                }
            }
            catch (JSONException e)
            {
                structuredLog.warning("failed_to_parse_perl_config_from_target_").field("detail", "Failed to parse Perl config from target: " ~ e.msg).emit();
            }
            catch (Exception e)
            {
                structuredLog.warning("error_processing_perl_config_").field("detail", "Error processing Perl config: " ~ e.msg).emit();
            }
        }
        
        // Auto-detect from project structure
        enhanceFromProject(config, target, workspace);
        
        return config;
    }
    
    bool validateInterpreter(in PerlConfig config) @trusted
    {
        import std.process : execute;
        
        string perlCmd = config.perlVersion.interpreterPath.empty 
            ? "perl" 
            : config.perlVersion.interpreterPath;
        
        try
        {
            auto result = execute([perlCmd, "--version"]);
            return result.status == 0;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    private void enhanceFromProject(
        ref PerlConfig config,
        in Target target,
        in WorkspaceConfig workspace
    ) @trusted
    {
        import std.path : buildPath;
        import std.file : exists;
        
        // Auto-detect build mode
        // Auto-detect mode if not specified
        if (false)  // Placeholder - mode detection removed
        {
            if (exists(buildPath(workspace.root, "cpanfile")))
                config.mode = PerlBuildMode.CPAN;
            else
                config.mode = PerlBuildMode.Script;
        }
        
        // Auto-detect build tool
        if (config.mode == PerlBuildMode.CPAN)
        {
            if (exists(buildPath(workspace.root, "Build.PL")))
                config.buildTool = PerlBuildTool.ModuleBuild;
            else if (exists(buildPath(workspace.root, "Makefile.PL")))
                config.buildTool = PerlBuildTool.MakeMaker;
            else if (exists(buildPath(workspace.root, "dist.ini")))
                config.buildTool = PerlBuildTool.DistZilla;
            else if (exists(buildPath(workspace.root, "minil.toml")))
                config.buildTool = PerlBuildTool.Minilla;
        }
        
        // Validate interpreter
        if (!validateInterpreter(config))
        {
            structuredLog.warning("perl_interpreter_not_available_").field("detail", "Perl interpreter not available: " ~ 
                          (config.perlVersion.interpreterPath.empty 
                           ? "perl" 
                           : config.perlVersion.interpreterPath)).emit();
        }
    }
    
    private PerlConfig parsePerlConfig(in JSONValue json) @trusted
    {
        import std.json : JSONType;
        import std.conv : to;
        
        PerlConfig config;
        
        try
        {
            // Parse Perl version
            if ("version" in json && json["version"].type == JSONType.object)
            {
                auto versionJson = json["version"];
                if ("major" in versionJson)
                    config.perlVersion.major = cast(int)versionJson["major"].integer;
                if ("minor" in versionJson)
                    config.perlVersion.minor = cast(int)versionJson["minor"].integer;
                if ("patch" in versionJson)
                    config.perlVersion.patch = cast(int)versionJson["patch"].integer;
                if ("interpreterPath" in versionJson)
                    config.perlVersion.interpreterPath = versionJson["interpreterPath"].str;
            }
            
            // Parse build mode
            if ("mode" in json && json["mode"].type == JSONType.string)
            {
                immutable modeStr = json["mode"].str;
                if (modeStr == "script")
                    config.mode = PerlBuildMode.Script;
                else if (modeStr == "cpan")
                    config.mode = PerlBuildMode.CPAN;
            }
            
            // Parse build tool
            if ("buildTool" in json && json["buildTool"].type == JSONType.string)
            {
                immutable toolStr = json["buildTool"].str;
                if (toolStr == "makemaker")
                    config.buildTool = PerlBuildTool.MakeMaker;
                else if (toolStr == "modulebuild")
                    config.buildTool = PerlBuildTool.ModuleBuild;
                else if (toolStr == "distzilla")
                    config.buildTool = PerlBuildTool.DistZilla;
                else if (toolStr == "minilla")
                    config.buildTool = PerlBuildTool.Minilla;
            }
            
            // Parse CPAN config
            if ("cpan" in json && json["cpan"].type == JSONType.object)
            {
                auto cpanJson = json["cpan"];
                if ("mirror" in cpanJson)
                    config.cpan.mirrors ~= cpanJson["mirror"].str;
                if ("mirrors" in cpanJson && cpanJson["mirrors"].type == JSONType.array)
                {
                    foreach (mirror; cpanJson["mirrors"].array)
                        config.cpan.mirrors ~= mirror.str;
                }
                if ("localLib" in cpanJson)
                    config.cpan.localLibDir = cpanJson["localLib"].str;
                if ("localLibDir" in cpanJson)
                    config.cpan.localLibDir = cpanJson["localLibDir"].str;
                if ("installBase" in cpanJson)
                    config.cpan.installBase = cpanJson["installBase"].str;
            }
            
            // Parse testing config
            if ("testing" in json && json["testing"].type == JSONType.object)
            {
                auto testingJson = json["testing"];
                if ("framework" in testingJson && testingJson["framework"].type == JSONType.string)
                {
                    immutable fwStr = testingJson["framework"].str;
                    if (fwStr == "test-more")
                        config.test.framework = PerlTestFramework.TestMore;
                    else if (fwStr == "test2")
                        config.test.framework = PerlTestFramework.Test2;
                    else if (fwStr == "test-class")
                        config.test.framework = PerlTestFramework.TestClass;
                    else
                        config.test.framework = PerlTestFramework.Auto;
                }
                if ("testPaths" in testingJson && testingJson["testPaths"].type == JSONType.array)
                {
                    foreach (path; testingJson["testPaths"].array)
                        config.test.testPaths ~= path.str;
                }
                if ("verbose" in testingJson)
                    config.test.verbose = testingJson["verbose"].type == JSONType.true_;
                if ("coverage" in testingJson)
                    config.test.coverage = testingJson["coverage"].type == JSONType.true_;
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("error_parsing_perl_config_fields_").field("detail", "Error parsing Perl config fields: " ~ e.msg).emit();
        }
        
        return config;
    }
}

