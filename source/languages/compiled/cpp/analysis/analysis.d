module languages.compiled.cpp.analysis.analysis;

import std.stdio;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import std.string;
import std.regex;
import infrastructure.utils.logging;

/// C++ header dependency analyzer
class HeaderAnalyzer
{
    /// Analyze header dependencies in a source file
    static string[] analyzeIncludes(string filePath)
    {
        if (!exists(filePath) || !isFile(filePath))
            return [];
        
        string[] includes;
        
        try
        {
            auto content = readText(filePath);
            
            // Regex for #include directives
            // Matches: #include "header.h" and #include <header.h>
            auto includeRegex = regex(`^\s*#\s*include\s+[<"]([^>"]+)[>"]`, "m");
            
            foreach (match; matchAll(content, includeRegex))
            {
                if (match.length > 1)
                {
                    includes ~= match[1];
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_analyze_includes_in_").field("detail", "Failed to analyze includes in " ~ filePath ~ ": " ~ e.msg).emit();
        }
        
        return includes;
    }
    
    /// Resolve header path based on include directories
    static string resolveHeader(string header, string[] includeDirs, string baseDir)
    {
        // If it's a relative path from baseDir
        string localPath = buildPath(baseDir, header);
        if (exists(localPath))
            return localPath;
        
        // Search in include directories
        foreach (incDir; includeDirs)
        {
            string fullPath = buildPath(incDir, header);
            if (exists(fullPath))
                return fullPath;
        }
        
        // Not found
        return "";
    }
    
    /// Build dependency graph for source files
    static string[][string] buildDependencyGraph(
        string[] sources,
        string[] includeDirs
    )
    {
        string[][string] graph;
        
        foreach (source; sources)
        {
            if (!exists(source))
                continue;
            
            string baseDir = dirName(source);
            auto includes = analyzeIncludes(source);
            
            string[] resolvedHeaders;
            foreach (header; includes)
            {
                string resolved = resolveHeader(header, includeDirs, baseDir);
                if (!resolved.empty)
                {
                    resolvedHeaders ~= resolved;
                }
            }
            
            graph[source] = resolvedHeaders;
        }
        
        return graph;
    }
    
    /// Find all transitively included headers
    static string[] findAllHeaders(string source, string[] includeDirs)
    {
        string[] allHeaders;
        string[] visited;
        string[] toVisit = [source];
        
        while (!toVisit.empty)
        {
            string current = toVisit[0];
            toVisit = toVisit[1 .. $];
            
            if (visited.canFind(current))
                continue;
            
            visited ~= current;
            
            string baseDir = dirName(current);
            auto includes = analyzeIncludes(current);
            
            foreach (header; includes)
            {
                string resolved = resolveHeader(header, includeDirs, baseDir);
                if (!resolved.empty && !visited.canFind(resolved))
                {
                    allHeaders ~= resolved;
                    toVisit ~= resolved;
                }
            }
        }
        
        return allHeaders;
    }
}

/// C++ template analyzer
class TemplateAnalyzer
{
    /// Detect if file contains template definitions
    static bool hasTemplates(string filePath)
    {
        if (!exists(filePath) || !isFile(filePath))
            return false;
        
        try
        {
            auto content = readText(filePath);
            
            // Look for template keywords
            auto templateRegex = regex(`\btemplate\s*<`, "m");
            return !matchFirst(content, templateRegex).empty;
        }
        catch (Exception e)
        {
            return false;
        }
    }
    
    /// Extract template declarations
    static string[] extractTemplateDecls(string filePath)
    {
        if (!exists(filePath) || !isFile(filePath))
            return [];
        
        string[] declarations;
        
        try
        {
            auto content = readText(filePath);
            
            // Regex for template declarations
            // This is simplified - real C++ parsing is much more complex
            auto templateRegex = regex(
                `template\s*<[^>]+>\s*(?:class|struct|typename|concept|using)\s+(\w+)`,
                "m"
            );
            
            foreach (match; matchAll(content, templateRegex))
            {
                if (match.length > 1)
                {
                    declarations ~= match[1];
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_extract_template_declarations_").field("detail", "Failed to extract template declarations from " ~ filePath).emit();
        }
        
        return declarations;
    }
    
    /// Check if file needs to be header-only (contains template definitions)
    static bool needsHeaderOnly(string filePath)
    {
        if (!exists(filePath) || !isFile(filePath))
            return false;
        
        try
        {
            auto content = readText(filePath);
            
            // Check for inline template definitions
            // Templates with implementations in header typically need to be header-only
            auto inlineTemplateRegex = regex(
                `template\s*<[^>]+>\s*(?:inline\s+)?(?:class|struct)[^{]+\{[^}]+\}`,
                "ms"
            );
            
            return !matchFirst(content, inlineTemplateRegex).empty;
        }
        catch (Exception e)
        {
            return false;
        }
    }
}

/// C++ macro analyzer
class MacroAnalyzer
{
    /// Extract #define macros from file
    static string[string] extractMacros(string filePath)
    {
        string[string] macros;
        
        if (!exists(filePath) || !isFile(filePath))
            return macros;
        
        try
        {
            auto content = readText(filePath);
            
            // Regex for #define directives
            auto defineRegex = regex(`^\s*#\s*define\s+(\w+)(?:\s+(.+))?$`, "m");
            
            foreach (match; matchAll(content, defineRegex))
            {
                if (match.length > 1)
                {
                    string name = match[1];
                    string value = match.length > 2 ? match[2].strip : "";
                    macros[name] = value;
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_extract_macros_from_").field("detail", "Failed to extract macros from " ~ filePath).emit();
        }
        
        return macros;
    }
    
    /// Find conditional compilation blocks
    static string[] findConditionalBlocks(string filePath)
    {
        string[] blocks;
        
        if (!exists(filePath) || !isFile(filePath))
            return blocks;
        
        try
        {
            auto content = readText(filePath);
            
            // Find #ifdef, #ifndef, #if defined, etc.
            auto conditionalRegex = regex(
                `^\s*#\s*(?:ifdef|ifndef|if)\s+(.+)$`,
                "m"
            );
            
            foreach (match; matchAll(content, conditionalRegex))
            {
                if (match.length > 1)
                {
                    blocks ~= match[1].strip;
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_find_conditional_blocks_in_").field("detail", "Failed to find conditional blocks in " ~ filePath).emit();
        }
        
        return blocks;
    }
}

/// C++ namespace analyzer
class NamespaceAnalyzer
{
    /// Extract namespaces from file
    static string[] extractNamespaces(string filePath)
    {
        string[] namespaces;
        
        if (!exists(filePath) || !isFile(filePath))
            return namespaces;
        
        try
        {
            auto content = readText(filePath);
            
            // Regex for namespace declarations
            auto namespaceRegex = regex(`\bnamespace\s+(\w+(?:::\w+)*)\s*\{`, "m");
            
            foreach (match; matchAll(content, namespaceRegex))
            {
                if (match.length > 1)
                {
                    namespaces ~= match[1];
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_extract_namespaces_from_").field("detail", "Failed to extract namespaces from " ~ filePath).emit();
        }
        
        return namespaces;
    }
}

/// C++ class/struct analyzer
class ClassAnalyzer
{
    /// Extract class and struct declarations
    static string[] extractClasses(string filePath)
    {
        string[] classes;
        
        if (!exists(filePath) || !isFile(filePath))
            return classes;
        
        try
        {
            auto content = readText(filePath);
            
            // Regex for class/struct declarations
            auto classRegex = regex(`\b(?:class|struct)\s+(?:__declspec\([^)]+\)\s+)?(\w+)`, "m");
            
            foreach (match; matchAll(content, classRegex))
            {
                if (match.length > 1)
                {
                    string className = match[1];
                    // Filter out common keywords that might match
                    if (className != "template" && className != "typename")
                    {
                        classes ~= className;
                    }
                }
            }
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_extract_classes_from_").field("detail", "Failed to extract classes from " ~ filePath).emit();
        }
        
        return classes;
    }
}

/// Precompiled header (PCH) optimizer
class PchOptimizer
{
    /// Suggest headers for precompilation based on usage frequency
    static string[] suggestPchHeaders(string[] sources, string[] includeDirs)
    {
        int[string] headerUsage;
        
        // Count header usage across all sources
        foreach (source; sources)
        {
            auto includes = HeaderAnalyzer.analyzeIncludes(source);
            foreach (header; includes)
            {
                headerUsage[header] = headerUsage.get(header, 0) + 1;
            }
        }
        
        // Sort by usage frequency
        auto sortedHeaders = headerUsage.byKeyValue
            .array
            .sort!((a, b) => a.value > b.value)
            .map!(kv => kv.key)
            .array;
        
        // Return top headers that are used in at least 30% of sources
        size_t threshold = sources.length / 3;
        string[] pchCandidates;
        
        foreach (header; sortedHeaders)
        {
            if (headerUsage[header] >= threshold)
            {
                pchCandidates ~= header;
            }
        }
        
        return pchCandidates;
    }
    
    /// Estimate PCH benefit (rough heuristic)
    static double estimatePchBenefit(string[] sources, string[] pchHeaders)
    {
        if (sources.empty || pchHeaders.empty)
            return 0.0;
        
        size_t totalIncludes = 0;
        size_t pchIncludes = 0;
        
        foreach (source; sources)
        {
            auto includes = HeaderAnalyzer.analyzeIncludes(source);
            totalIncludes += includes.length;
            
            foreach (include; includes)
            {
                if (pchHeaders.canFind(include))
                {
                    pchIncludes++;
                }
            }
        }
        
        if (totalIncludes == 0)
            return 0.0;
        
        // Return percentage of includes that would be precompiled
        return cast(double)pchIncludes / cast(double)totalIncludes * 100.0;
    }
}

