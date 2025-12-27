module languages.scripting.perl.services.documentation;

import languages.scripting.perl.core.config;
import engine.caching.actions.action;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;

/// Documentation generation service interface
interface IPerlDocumentationService
{
    /// Generate documentation from POD
    void generate(in string[] sources, in PerlConfig config, 
                 string projectRoot, ActionCache cache);
}

/// Concrete Perl documentation service
final class PerlDocumentationService : IPerlDocumentationService
{
    void generate(
        in string[] sources,
        in PerlConfig config,
        string projectRoot,
        ActionCache cache
    ) @trusted
    {
        import std.file : exists, isFile, mkdirRecurse;
        import std.path : buildPath, baseName, stripExtension;
        import std.process : execute;
        import std.conv : to;
        
        PerlDocGenerator generator = config.documentation.generator;
        if (generator == PerlDocGenerator.None)
            return;
        
        if (generator == PerlDocGenerator.Auto)
        {
            generator = PerlDocGenerator.Pod2HTML;
        }
        
        string outputDir = buildPath(projectRoot, config.documentation.outputDir);
        if (!exists(outputDir))
        {
            mkdirRecurse(outputDir);
        }
        
        foreach (source; sources)
        {
            if (!exists(source) || !isFile(source))
                continue;
            
            auto name = source.baseName.stripExtension;
            
            // Generate HTML
            if (generator == PerlDocGenerator.Pod2HTML || 
                generator == PerlDocGenerator.Both)
            {
                generateHTML(source, name, outputDir, cache);
            }
            
            // Generate man pages
            if ((generator == PerlDocGenerator.Pod2Man || 
                 generator == PerlDocGenerator.Both) &&
                config.documentation.generateMan)
            {
                generateMan(source, name, outputDir, config, cache);
            }
        }
    }
    
    private void generateHTML(
        string source,
        string baseName,
        string outputDir,
        ActionCache cache
    ) @trusted
    {
        import std.path : buildPath;
        import std.process : execute;
        import std.file : exists;
        
        string htmlOutput = buildPath(outputDir, baseName ~ ".html");
        
        // Build metadata
        string[string] metadata;
        metadata["generator"] = "pod2html";
        metadata["outputDir"] = outputDir;
        
        // Create action ID
        ActionId actionId;
        actionId.targetId = "pod_docs";
        actionId.type = ActionType.Custom;
        actionId.subId = baseName ~ "_html";
        actionId.inputHash = FastHash.hashFile(source);
        
        // Check cache
        if (cache.isCached(actionId, [source], metadata) && exists(htmlOutput))
        {
            structuredLog.debug_("__cached_pod_html_").field("detail", "  [Cached] POD HTML: " ~ baseName).emit();
            return;
        }
        
        // Generate
        try
        {
            auto res = execute(["pod2html", 
                              "--infile=" ~ source, 
                              "--outfile=" ~ htmlOutput]);
            bool success = (res.status == 0);
            
            cache.update(actionId, [source], [htmlOutput], metadata, success);
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_generate_html_docs_for_").field("detail", "Failed to generate HTML docs for " ~ source).emit();
            cache.update(actionId, [source], [], metadata, false);
        }
    }
    
    private void generateMan(
        string source,
        string baseName,
        string outputDir,
        in PerlConfig config,
        ActionCache cache
    ) @trusted
    {
        import std.path : buildPath;
        import std.process : execute;
        import std.file : exists;
        import std.conv : to;
        
        string manOutput = buildPath(outputDir, 
                                     baseName ~ "." ~ config.documentation.manSection.to!string);
        
        // Build metadata
        string[string] metadata;
        metadata["generator"] = "pod2man";
        metadata["manSection"] = config.documentation.manSection.to!string;
        metadata["outputDir"] = outputDir;
        
        // Create action ID
        ActionId actionId;
        actionId.targetId = "pod_docs";
        actionId.type = ActionType.Custom;
        actionId.subId = baseName ~ "_man";
        actionId.inputHash = FastHash.hashFile(source);
        
        // Check cache
        if (cache.isCached(actionId, [source], metadata) && exists(manOutput))
        {
            structuredLog.debug_("__cached_pod_man_").field("detail", "  [Cached] POD man: " ~ baseName).emit();
            return;
        }
        
        // Generate
        try
        {
            auto res = execute(["pod2man", source, manOutput]);
            bool success = (res.status == 0);
            
            cache.update(actionId, [source], [manOutput], metadata, success);
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_generate_man_page_for_").field("detail", "Failed to generate man page for " ~ source).emit();
            cache.update(actionId, [source], [], metadata, false);
        }
    }
}

