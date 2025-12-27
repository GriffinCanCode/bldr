module languages.compiled.d.analysis.modules;

import std.stdio;
import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.regex;
import infrastructure.utils.logging;

/// D module information
struct ModuleInfo
{
    /// Module name (e.g., std.stdio, app.core)
    string name;
    
    /// File path
    string path;
    
    /// Import statements
    string[] imports;
    
    /// Public imports
    string[] publicImports;
    
    /// Static imports
    string[] staticImports;
    
    /// Module declaration
    string moduleDeclaration;
}

/// D module dependency analyzer
class ModuleAnalyzer
{
    /// Analyze D source file for module information
    static ModuleInfo analyze(string filePath)
    {
        ModuleInfo info;
        info.path = filePath;
        
        if (!exists(filePath) || !isFile(filePath))
        {
            structuredLog.warning("file_not_found_").field("detail", "File not found: " ~ filePath).emit();
            return info;
        }
        
        try
        {
            string content = readText(filePath);
            
            // Parse module declaration
            info.moduleDeclaration = parseModuleDeclaration(content);
            if (!info.moduleDeclaration.empty)
            {
                info.name = info.moduleDeclaration;
            }
            else
            {
                // Infer module name from file path
                info.name = inferModuleName(filePath);
            }
            
            // Parse imports
            parseImports(content, info);
        }
        catch (Exception e)
        {
            structuredLog.warning("failed_to_analyze_module_").field("detail", "Failed to analyze module " ~ filePath ~ ": " ~ e.msg).emit();
        }
        
        return info;
    }
    
    /// Analyze multiple D source files
    static ModuleInfo[] analyzeMultiple(string[] filePaths)
    {
        ModuleInfo[] modules;
        
        foreach (path; filePaths)
        {
            if (path.endsWith(".d"))
            {
                modules ~= analyze(path);
            }
        }
        
        return modules;
    }
    
    /// Build dependency graph from modules
    static string[][string] buildDependencyGraph(ModuleInfo[] modules)
    {
        string[][string] graph;
        
        foreach (mod; modules)
        {
            graph[mod.name] = mod.imports ~ mod.publicImports ~ mod.staticImports;
        }
        
        return graph;
    }
    
    /// Parse module declaration
    private static string parseModuleDeclaration(string content)
    {
        // Match: module package.name;
        auto moduleRegex = regex(`^\s*module\s+([\w.]+)\s*;", "m`);
        auto match = matchFirst(content, moduleRegex);
        
        if (!match.empty && match.length >= 2)
        {
            return match[1];
        }
        
        return "";
    }
    
    /// Infer module name from file path
    private static string inferModuleName(string filePath)
    {
        // Remove extension
        string name = baseName(filePath, ".d");
        
        // Get relative path components
        string dir = dirName(filePath);
        string[] parts;
        
        // Simple heuristic: use last few directory components
        if (dir != "." && dir != ".." && !dir.empty)
        {
            parts = dir.split(dirSeparator);
            
            // Skip common prefixes
            while (!parts.empty && (parts[0] == "." || parts[0] == ".." || 
                   parts[0] == "source" || parts[0] == "src"))
            {
                parts = parts[1..$];
            }
        }
        
        parts ~= name;
        return parts.join(".");
    }
    
    /// Parse import statements
    private static void parseImports(string content, ref ModuleInfo info)
    {
        // Remove comments to avoid false positives
        content = removeComments(content);
        
        // Match: import module.name;
        auto importRegex = regex(`^\s*import\s+([\w.]+(?:\s*,\s*[\w.]+)*)\s*;", "m`);
        
        foreach (match; matchAll(content, importRegex))
        {
            if (match.length >= 2)
            {
                string importList = match[1];
                
                // Split multiple imports on same line
                foreach (imp; importList.split(","))
                {
                    string cleaned = imp.strip();
                    if (!cleaned.empty)
                    {
                        info.imports ~= cleaned;
                    }
                }
            }
        }
        
        // Match: public import module.name;
        auto publicImportRegex = regex(`^\s*public\s+import\s+([\w.]+(?:\s*,\s*[\w.]+)*)\s*;", "m`);
        
        foreach (match; matchAll(content, publicImportRegex))
        {
            if (match.length >= 2)
            {
                string importList = match[1];
                
                foreach (imp; importList.split(","))
                {
                    string cleaned = imp.strip();
                    if (!cleaned.empty)
                    {
                        info.publicImports ~= cleaned;
                    }
                }
            }
        }
        
        // Match: static import module.name;
        auto staticImportRegex = regex(`^\s*static\s+import\s+([\w.]+(?:\s*,\s*[\w.]+)*)\s*;", "m`);
        
        foreach (match; matchAll(content, staticImportRegex))
        {
            if (match.length >= 2)
            {
                string importList = match[1];
                
                foreach (imp; importList.split(","))
                {
                    string cleaned = imp.strip();
                    if (!cleaned.empty)
                    {
                        info.staticImports ~= cleaned;
                    }
                }
            }
        }
        
        // Match: import module.name : symbols;
        auto selectiveImportRegex = regex(`^\s*import\s+([\w.]+)\s*:\s*[^;]+;", "m`);
        
        foreach (match; matchAll(content, selectiveImportRegex))
        {
            if (match.length >= 2)
            {
                string moduleName = match[1].strip();
                if (!moduleName.empty && !info.imports.canFind(moduleName))
                {
                    info.imports ~= moduleName;
                }
            }
        }
    }
    
    /// Remove comments from source code
    private static string removeComments(string content)
    {
        string result = content;
        
        // Remove block comments /* ... */
        result = replaceAll(result, regex(`/\*.*?\*/`, "s"), "");
        
        // Remove nested block comments /+ ... +/
        result = removeNestedComments(result);
        
        // Remove line comments //
        result = replaceAll(result, regex(`//.*?$`, "m"), "");
        
        return result;
    }
    
    /// Remove nested block comments /+ ... +/
    private static string removeNestedComments(string content)
    {
        string result;
        int depth = 0;
        bool inString = false;
        char stringChar = '\0';
        
        for (size_t i = 0; i < content.length; i++)
        {
            char c = content[i];
            
            // Handle string literals
            if ((c == '"' || c == '\'') && (i == 0 || content[i-1] != '\\'))
            {
                if (inString && c == stringChar)
                {
                    inString = false;
                }
                else if (!inString && depth == 0)
                {
                    inString = true;
                    stringChar = c;
                }
            }
            
            if (!inString && depth == 0)
            {
                // Check for comment start /+
                if (i + 1 < content.length && c == '/' && content[i+1] == '+')
                {
                    depth = 1;
                    i++; // Skip '+'
                    continue;
                }
            }
            
            if (!inString && depth > 0)
            {
                // Check for nested comment start /+
                if (i + 1 < content.length && c == '/' && content[i+1] == '+')
                {
                    depth++;
                    i++; // Skip '+'
                    continue;
                }
                
                // Check for comment end +/
                if (i + 1 < content.length && c == '+' && content[i+1] == '/')
                {
                    depth--;
                    i++; // Skip '/'
                    continue;
                }
            }
            
            if (depth == 0)
            {
                result ~= c;
            }
        }
        
        return result;
    }
}


