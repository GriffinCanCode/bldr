module languages.compiled.nim.builders.doc;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import languages.compiled.nim.builders.base;
import languages.compiled.nim.core.config;
import languages.compiled.nim.tooling.tools;
import infrastructure.config.schema.schema;
import infrastructure.analysis.targets.types;
import infrastructure.utils.files.hash;
import infrastructure.utils.logging;
import engine.caching.actions.action : ActionCache;

/// Documentation generator builder
class DocBuilder : NimBuilder
{
    void setActionCache(ActionCache cache)
    {
        // Doc builder doesn't use caching currently
    }
    
    NimCompileResult build(
        in string[] sources,
        in NimConfig config,
        in Target target,
        in WorkspaceConfig workspace
    )
    {
        NimCompileResult result;
        
        if (sources.empty && config.entry.empty)
        {
            result.error = "No source files specified";
            return result;
        }
        
        // Generate documentation for all sources
        string[] filesToDoc = config.entry.empty ? sources.dup : cast(string[])[config.entry];
        string[] outputFiles;
        
        foreach (source; filesToDoc)
        {
            if (!exists(source))
            {
                result.error = "Source file not found: " ~ source;
                return result;
            }
            
            auto docResult = generateDocs(source, config);
            
            if (!docResult.success)
            {
                result.error = docResult.error;
                return result;
            }
            
            outputFiles ~= docResult.outputs;
            result.warnings ~= docResult.warnings;
            result.hints ~= docResult.hints;
        }
        
        // Generate index if requested
        if (config.doc.genIndex && outputFiles.length > 1)
        {
            generateIndex(outputFiles, config);
        }
        
        result.success = true;
        result.outputs = outputFiles;
        result.artifacts = [config.doc.outputDir];
        
        if (!outputFiles.empty)
            result.outputHash = FastHash.hashStrings(outputFiles);
        else
            result.outputHash = FastHash.hashString(config.doc.outputDir);
        
        return result;
    }
    
    bool isAvailable()
    {
        return NimTools.isNimAvailable();
    }
    
    string name() const
    {
        return "nim-doc";
    }
    
    string getVersion()
    {
        return NimTools.getNimVersion();
    }
    
    bool supportsFeature(string feature)
    {
        return feature == "doc" || feature == "documentation";
    }
    
    private NimCompileResult generateDocs(string source, in NimConfig config)
    {
        NimCompileResult result;
        
        // Ensure output directory exists
        if (!exists(config.doc.outputDir))
            mkdirRecurse(config.doc.outputDir);
        
        // Build doc command
        string[] cmd = ["nim", "doc"];
        
        // Output directory
        cmd ~= "--outdir:" ~ config.doc.outputDir;
        
        // Project name
        if (!config.doc.project.empty)
            cmd ~= "--project:" ~ config.doc.project;
        
        // Index generation
        if (config.doc.genIndex)
            cmd ~= "--index:on";
        
        // Include source code
        if (config.doc.includeSource)
            cmd ~= "--embedsrc";
        
        // Custom title
        if (!config.doc.title.empty)
            cmd ~= "--docTitle:" ~ config.doc.title;
        
        // Git repository integration
        cmd ~= "--git.url:auto";
        cmd ~= "--git.commit:auto";
        
        // Paths
        foreach (path; config.path.paths)
            cmd ~= "--path:" ~ path;
        
        // Defines
        foreach (define; config.defines)
            cmd ~= "-d:" ~ define;
        
        // Hints control (less noise for doc generation)
        cmd ~= "--hint:Conf:off";
        cmd ~= "--hint:Path:off";
        
        // Source file
        cmd ~= source;
        
        if (config.verbose)
        {
            structuredLog.info("doc_generation_command_").field("detail", "Doc generation command: " ~ cmd.join(" ")).emit();
        }
        
        // Execute doc generation
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            result.error = "Documentation generation failed for " ~ source ~ ": " ~ res.output;
            return result;
        }
        
        // Determine output file
        string baseName = stripExtension(baseName(source));
        string outputFile = buildPath(config.doc.outputDir, baseName ~ ".html");
        
        if (!exists(outputFile))
        {
            structuredLog.warning("expected_documentation_file_not_found_").field("detail", "Expected documentation file not found: " ~ outputFile).emit();
        }
        
        result.success = true;
        result.outputs = [outputFile];
        
        return result;
    }
    
    private void generateIndex(string[] docFiles, in NimConfig config)
    {
        // Generate theindex.html using nim buildIndex
        string[] cmd = ["nim", "buildIndex"];
        
        cmd ~= "--outdir:" ~ config.doc.outputDir;
        
        if (!config.doc.project.empty)
            cmd ~= "--project:" ~ config.doc.project;
        
        auto res = execute(cmd, null, std.process.Config.none, size_t.max, config.doc.outputDir);
        
        if (res.status != 0)
        {
            structuredLog.warning("index_generation_failed_").field("detail", "Index generation failed: " ~ res.output).emit();
        }
        else
        {
            structuredLog.info("generated_documentation_index").emit();
        }
    }
}

