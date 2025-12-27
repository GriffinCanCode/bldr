module languages.scripting.elixir.tooling.docs.generator;

import std.stdio;
import std.process;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import languages.scripting.elixir.config;
import infrastructure.utils.logging;

/// Documentation generator (ExDoc)
class DocGenerator
{
    /// Generate documentation
    static bool generate(DocConfig config, string mixCmd = "mix")
    {
        if (!isExDocAvailable(mixCmd))
        {
            structuredLog.warning("exdoc_not_available_add_ex_doc_").field("detail", "ExDoc not available (add {:ex_doc, \"~> 0.31\", only: :dev} to deps)").emit();
            return false;
        }
        
        structuredLog.info("generating_documentation").emit();
        
        string[] cmd = [mixCmd, "docs"];
        
        // ExDoc configuration is typically in mix.exs under project() or docs()
        // So we don't need to pass many CLI options
        
        auto res = execute(cmd);
        
        if (res.status != 0)
        {
            structuredLog.error("documentation_generation_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        string docPath = config.output.empty ? "doc" : config.output;
        if (exists(docPath))
        {
            structuredLog.info("documentation_generated_at_").field("detail", "Documentation generated at: " ~ docPath).emit();
        }
        
        return true;
    }
    
    /// Check if ExDoc is available
    static bool isExDocAvailable(string mixCmd = "mix")
    {
        auto res = execute([mixCmd, "help", "docs"]);
        return res.status == 0;
    }
    
    /// Generate documentation for Hex package
    static bool generateForHex(DocConfig config, string mixCmd = "mix")
    {
        structuredLog.info("building_documentation_for_hex").emit();
        
        auto res = execute([mixCmd, "hex.build", "docs"]);
        
        if (res.status != 0)
        {
            structuredLog.error("hex_docs_build_failed").emit();
            structuredLog.error("__output_").field("detail", "  Output: " ~ res.output).emit();
            return false;
        }
        
        return true;
    }
}

