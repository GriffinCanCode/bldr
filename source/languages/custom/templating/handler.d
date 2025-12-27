module languages.custom.templating.handler;

import std.stdio;
import std.file : exists, isFile, readText, mkdirRecurse, write;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.conv;
import languages.base.base;
import infrastructure.config.schema.schema;
import engine.graph;
import infrastructure.analysis.targets.types;
import infrastructure.utils.logging;
import infrastructure.utils.files.hash;

/// Template expansion handler with dynamic discovery
/// Supports mustache-style templates that generate source files
class TemplateHandler : BaseLanguageHandler, DiscoverableAction
{
    protected override LanguageBuildResult buildImplWithContext(in BuildContext context)
    {
        // Extract target and config from context for convenience
        auto target = context.target;
        auto config = context.config;
        
        LanguageBuildResult result;
        
        // Template expansion happens in executeWithDiscovery
        // This is just for compatibility
        result.success = true;
        result.outputHash = FastHash.hashString("template-expanded");
        
        return result;
    }
    
    override string[] getOutputs(in Target target, in WorkspaceConfig config)
    {
        // Outputs are discovered at build time
        return [buildPath(config.options.outputDir, "generated")];
    }
    
    override Import[] analyzeImports(in string[] sources)
    {
        // Templates don't have traditional imports
        return [];
    }
    
    /// Execute with discovery to expand templates and discover generated files
    DiscoveryResult executeWithDiscovery(Target target, WorkspaceConfig config) @system
    {
        DiscoveryResult result;
        result.success = false;
        result.hasDiscovery = false;
        
        structuredLog.info("executing_template_expansion_for_").field("detail", "Executing template expansion for " ~ target.name).emit();
        
        // Parse template configuration
        auto templateConfig = parseTemplateConfig(target);
        
        // Expand templates
        string[] generatedFiles;
        foreach (templateFile; target.sources)
        {
            if (!exists(templateFile))
            {
                result.error = "Template file not found: " ~ templateFile;
                return result;
            }
            
            try
            {
                auto expanded = expandTemplate(templateFile, templateConfig, config);
                generatedFiles ~= expanded;
            }
            catch (Exception e)
            {
                result.error = "Failed to expand template " ~ templateFile ~ ": " ~ e.msg;
                return result;
            }
        }
        
        result.success = true;
        
        if (generatedFiles.empty)
        {
            // No files generated
            return result;
        }
        
        // Create discovery metadata
        result.hasDiscovery = true;
        
        auto builder = DiscoveryBuilder.forTarget(target.id);
        builder = builder.addOutputs(generatedFiles);
        builder = builder.withMetadata("generator", "template-engine");
        builder = builder.withMetadata("template_count", target.sources.length.to!string);
        
        // Group generated files by language and create compile targets
        auto targetsByLang = groupByLanguage(generatedFiles);
        
        Target[] compileTargets;
        TargetId[] compileIds;
        
        foreach (lang, files; targetsByLang)
        {
            auto targetName = target.name ~ "-generated-" ~ lang;
            auto targetId = TargetId(targetName);
            
            Target compileTarget;
            compileTarget.name = targetName;
            compileTarget.sources = files;
            compileTarget.deps = [target.id.toString()];
            compileTarget.type = TargetType.Library;
            compileTarget.language = inferLanguage(lang);
            
            if (compileTarget.language != TargetLanguage.Generic)
            {
                compileTargets ~= compileTarget;
                compileIds ~= targetId;
            }
        }
        
        if (!compileTargets.empty)
        {
            builder = builder.addTargets(compileTargets);
            builder = builder.addDependents(compileIds);
            
            structuredLog.info("discovered_").field("detail", "Discovered " ~ compileTargets.length.to!string ~ 
                         " compile targets from template expansion").emit();
        }
        
        result.discovery = builder.build();
        return result;
    }
    
    /// Expand a single template file
    private string expandTemplate(string templateFile, TemplateConfig config, WorkspaceConfig wsConfig) @system
    {
        auto templateContent = readText(templateFile);
        auto outputDir = buildPath(wsConfig.options.outputDir, "generated");
        
        if (!exists(outputDir))
            mkdirRecurse(outputDir);
        
        // Simple mustache-style template expansion
        string expanded = templateContent;
        
        // Replace variables
        foreach (key, value; config.variables)
        {
            expanded = expanded.replace("{{" ~ key ~ "}}", value);
        }
        
        // Determine output file name
        auto baseName = templateFile.baseName.stripExtension;
        auto outputExt = config.outputExtension.empty ? ".generated" : config.outputExtension;
        auto outputFile = buildPath(outputDir, baseName ~ outputExt);
        
        // Write expanded template
        write(outputFile, expanded);
        
        structuredLog.debug_("expanded_template_").field("detail", "Expanded template: " ~ templateFile ~ " → " ~ outputFile).emit();
        
        return outputFile;
    }
    
    /// Parse template configuration
    private TemplateConfig parseTemplateConfig(in Target target) @system
    {
        TemplateConfig config;
        
        // Parse from langConfig
        if ("template" in target.langConfig)
        {
            import std.json;
            try
            {
                auto json = parseJSON(target.langConfig["template"]);
                
                if ("variables" in json)
                {
                    foreach (key, value; json["variables"].object)
                    {
                        config.variables[key] = value.str;
                    }
                }
                
                if ("outputExtension" in json)
                {
                    config.outputExtension = json["outputExtension"].str;
                }
            }
            catch (Exception e)
            {
                structuredLog.warning("failed_to_parse_template_config_").field("detail", "Failed to parse template config: " ~ e.msg).emit();
            }
        }
        
        return config;
    }
    
    /// Group files by extension/language
    private string[][string] groupByLanguage(string[] files) @system
    {
        string[][string] groups;
        
        foreach (file; files)
        {
            auto ext = extension(file);
            if (ext !in groups)
                groups[ext] = [];
            groups[ext] ~= file;
        }
        
        return groups;
    }
    
    /// Infer language from extension
    private TargetLanguage inferLanguage(string ext) @system
    {
        switch (ext)
        {
            case ".cpp", ".cc", ".cxx": return TargetLanguage.Cpp;
            case ".c": return TargetLanguage.C;
            case ".d": return TargetLanguage.D;
            case ".go": return TargetLanguage.Go;
            case ".rs": return TargetLanguage.Rust;
            case ".py": return TargetLanguage.Python;
            case ".js": return TargetLanguage.JavaScript;
            case ".ts": return TargetLanguage.TypeScript;
            case ".java": return TargetLanguage.Java;
            default: return TargetLanguage.Generic;
        }
    }
}

/// Template configuration
struct TemplateConfig
{
    string[string] variables;
    string outputExtension;
}


