module infrastructure.analysis.scanning.scanner;

import std.stdio;
import std.file;
import std.algorithm;
import std.array;
import std.regex;
import std.string;
import infrastructure.utils.logging : Logger, structuredLog;

/// Fast file scanner for dependency analysis
class FileScanner
{
    /// Scan a file for imports using a regex pattern
    string[] scanImports(string path, Regex!char pattern)
    {
        if (!exists(path) || !isFile(path))
            return [];
        
        string[] imports;
        
        try
        {
            auto content = readText(path);
            
            foreach (match; matchAll(content, pattern))
            {
                // Check both capture groups (for "from X import" and "import X")
                for (size_t i = 1; i < match.length; i++)
                {
                    auto importName = match[i].strip();
                    if (!importName.empty && !imports.canFind(importName))
                        imports ~= importName;
                }
            }
        }
        catch (Exception e)
        {
            // File read error, log for debugging
            import infrastructure.utils.logging.logger : Logger;
            structuredLog.debug_("failed_to_scan_file_for_imports_").field("detail", "Failed to scan file for imports: " ~ path ~ ": " ~ e.msg).emit();
        }
        
        return imports;
    }
    
    /// Scan multiple files in parallel using work-stealing scheduler
    /// Optimized for variable file sizes and analysis times
    string[][string] scanImportsParallel(string[] paths, Regex!char pattern)
    {
        import infrastructure.utils.concurrency.parallel;
        import std.typecons : Tuple, tuple;
        
        if (paths.empty)
            return null;
        
        // Use work-stealing for better load balancing
        alias ScanResult = Tuple!(string, string[]);
        auto results = ParallelExecutor.mapWorkStealing(
            paths,
            (string path) @system {
                auto imports = scanImports(path, pattern);
                return tuple(path, imports);
            }
        );
        
        // Convert array of tuples to associative array
        string[][string] resultMap;
        foreach (result; results)
            resultMap[result[0]] = result[1];
        
        return resultMap;
    }
    
    /// Check if file has changed since last scan
    bool hasChanged(string path, string lastHash)
    {
        import infrastructure.utils.files.hash;
        
        if (!exists(path))
            return true;
        
        auto currentHash = FastHash.hashMetadata(path);
        return currentHash != lastHash;
    }
}

